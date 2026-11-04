#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# GenAI with llguidance on every lane: args, DLL gate, stage mounts and the smoke script against a fake binding; NOT covered: a real build or inference.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsTargetArch.Common.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
$script:GenaiScript = 'windows\scripts\build\Build-OnnxGenaiFromSource.ps1'
. (Get-ScriptFunctionDefinition -ScriptPath $script:GenaiScript -FunctionName 'Get-GenaiGuidanceCmakeArgs', 'Get-GenaiGuidanceFinding', 'Install-GenaiRustTarget')

$script:GuidanceCache = @'
USE_GUIDANCE:BOOL=ON
Rust_CARGO_TARGET:UNINITIALIZED=x86_64-pc-windows-msvc
'@
$script:GuidanceDllText = "..Error creating llg_tokenizer: ..deps\llguidance-src\toktrie\src\tokenv.rs.."

function script:Get-GuidanceFindingFor {
    param([string]$Cache = $script:GuidanceCache, [string]$DllText = $script:GuidanceDllText, [string]$Arch = 'amd64')
    Invoke-InTestDir { param($root)
        $dll = Join-Path $root 'onnxruntime-genai.dll'
        [IO.File]::WriteAllText($dll, $DllText)
        @(Get-GenaiGuidanceFinding -CMakeCache $Cache -GenaiDll $dll -TargetArch $Arch)
    }
}

Describe 'GenAI llguidance: the build arguments' {
    It 'turns guidance on and names the Rust target of each lane' {
        Assert-Equal '-DUSE_GUIDANCE=ON|-DRust_CARGO_TARGET=x86_64-pc-windows-msvc' (@(Get-GenaiGuidanceCmakeArgs -TargetArch amd64) -join '|')
        Assert-Equal '-DUSE_GUIDANCE=ON|-DRust_CARGO_TARGET=aarch64-pc-windows-msvc' (@(Get-GenaiGuidanceCmakeArgs -TargetArch arm64) -join '|')
    }
    It 'leaves no switch that turns guidance off' {
        $body = (Get-TestScriptAst -ScriptPath $script:GenaiScript).Extent.Text
        Assert-True ($body -notmatch 'USE_GUIDANCE=OFF') 'USE_GUIDANCE=OFF is gone'
    }
}

Describe 'GenAI llguidance: the DLL gate' {
    It 'passes a configured build whose DLL carries both markers' {
        Assert-Equal 0 @(Get-GuidanceFindingFor).Count 'no finding'
    }
    It 'fails when configure did not enable guidance' {
        Assert-Match 'USE_GUIDANCE=OFF, not ON' ((Get-GuidanceFindingFor -Cache ($script:GuidanceCache -replace 'BOOL=ON', 'BOOL=OFF')) -join ';')
    }
    It 'fails when the Rust target is not the lane''s' {
        Assert-Match 'Rust_CARGO_TARGET=x86_64-pc-windows-msvc, not aarch64-pc-windows-msvc' ((Get-GuidanceFindingFor -Arch arm64) -join ';')
    }
    It 'fails on each missing marker: the C++ guard, the Rust parser' {
        Assert-Match "no 'Error creating llg_tokenizer'" ((Get-GuidanceFindingFor -DllText 'toktrie') -join ';')
        Assert-Match "no 'toktrie'" ((Get-GuidanceFindingFor -DllText 'Error creating llg_tokenizer') -join ';')
    }
    It 'fails when the unused llguidance build outputs reach the install' {
        Invoke-InTestDir { param($root)
            $dll = Join-Path $root 'onnxruntime-genai.dll'
            [IO.File]::WriteAllText($dll, $script:GuidanceDllText)
            [IO.File]::WriteAllText((Join-Path $root 'llguidance.lib'), 'x')
            Assert-Match 'llguidance.lib is in the install' (@(Get-GenaiGuidanceFinding -CMakeCache $script:GuidanceCache -GenaiDll $dll -TargetArch amd64) -join ';')
        }
    }
    It 'fails on an absent DLL and an empty cache' {
        $missing = @(Get-GenaiGuidanceFinding -CMakeCache '' -GenaiDll (Join-Path ([IO.Path]::GetTempPath()) 'no-such-genai.dll') -TargetArch amd64) -join ';'
        Assert-Match 'USE_GUIDANCE=, not ON' $missing
        Assert-Match 'no GenAI DLL at' $missing
    }
}

Describe 'GenAI llguidance: wiring' {
    $ast = Get-TestScriptAst -ScriptPath $script:GenaiScript
    function script:Get-GuidanceTopLevelCall {
        param([string]$Name)
        @(Get-TestAstCommands -Ast $ast -Name $Name | Where-Object {
                $null -eq (Get-TestAstAncestor -Node $_ -First -Predicate { param($a)
                        $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                        $a -is [System.Management.Automation.Language.IfStatementAst] -or
                        $a -is [System.Management.Automation.Language.LoopStatementAst] })
            })
    }
    It 'prepares Rust and the scratch cargo home before configure, and gates after the install, unconditionally' {
        $target = @(Get-GuidanceTopLevelCall 'Install-GenaiRustTarget')
        $configure = @(Get-GuidanceTopLevelCall 'Invoke-CmakeConfigure')
        $install = @(Get-GuidanceTopLevelCall 'Install-GenaiBuiltArtifacts')
        $gate = @(Get-GuidanceTopLevelCall 'Assert-GenaiGuidance')
        Assert-Equal 1 $target.Count 'one Install-GenaiRustTarget'
        Assert-Equal 1 $gate.Count 'one gate'
        Assert-True ($target[0].Extent.EndOffset -lt $configure[0].Extent.StartOffset) 'the target exists before configure'
        Assert-True ($install[0].Extent.EndOffset -lt $gate[0].Extent.StartOffset) 'the gate reads the installed DLL'
        Assert-Match "CARGO_HOME = Join-Path \`$SourceDir 'cargo-home'" $ast.Extent.Text
    }
    It 'removes llguidance from the install before the gate reads it' {
        $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-GenaiBuiltArtifacts' }, $true))[0].Extent.Text
        Assert-Match "-Filter 'llguidance\*' -File \| Remove-Item -Force" $fn
    }
    It 'throws on a finding (mutation)' {
        Assert-Match 'if \(\$genaiGuidance\.Count -gt 0\) \{ throw ' $ast.Extent.Text
    }
    It 'mounts the Rust leaf and its sibling on the GenAI RUN alone, never in buildmods' {
        $dockerfile = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder'))
        foreach ($leaf in 'WindowsRustToolchain.Common.psm1', 'WindowsScripts.Shared.psm1') {
            Assert-Match ("source=windows/scripts/modules/$leaf,target=C:\\bkmnt\\rustmods\\$leaf") $dockerfile
        }
        Assert-Equal 1 ([regex]::Matches($dockerfile, 'rustmods\\WindowsRustToolchain')).Count 'one stage carries it'
        $genaiRun = [regex]::Match($dockerfile, "(?s)RUN --mount(?:(?!RUN --mount).)*-ResumeFrom 'ONNX GenAI'").Value
        Assert-Match 'rustmods\\WindowsRustToolchain' $genaiRun 'the GenAI RUN'
        Assert-True ($dockerfile -notmatch 'windows\\scripts\\modules\\WindowsRustToolchain') 'not COPYd into buildmods'
    }
    It 'ships the smoke script with the shared fixture and calls it from the Base group' {
        $image = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile'))
        Assert-Match 'genai-guidance-smoke\.py' $image
        Assert-Match 'linux\\scripts\\lib\\tiny-genai-model\.py' $image 'the shared fixture ships beside it'
        $smoke = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Container.ps1'))
        Assert-Match "Resolve-SmokeCompanion -ScriptRoot \`$PSScriptRoot -Name 'genai-guidance-smoke\.py'" $smoke
        Assert-Match "Resolve-SmokeCompanion -ScriptRoot \`$PSScriptRoot -Name 'tiny-genai-model\.py'" $smoke
        Assert-Match 'genai-guidance-schema-ok 7' $smoke
    }
}

Describe 'GenAI llguidance: the smoke script against a fake binding' {
    $python = (Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $smokeScript = Join-Path (Get-RepoRoot) 'windows\scripts\build\genai-guidance-smoke.py'
    $fixtureScript = Join-Path (Get-RepoRoot) 'linux\scripts\lib\tiny-genai-model.py'
    function script:Invoke-GuidanceSmoke {
        param([string]$Control, [string]$Answer, [string]$Extra = 'pass')
        Invoke-InTestDir { param($root)
            [IO.File]::WriteAllText((Join-Path $root 'onnxruntime_genai.py'), @"
import json, pathlib
last = ''
class Model:
    def __init__(self, path): assert (pathlib.Path(path) / 'model.onnx').stat().st_size > 0
class Tokenizer:
    def __init__(self, model): pass
    def decode(self, tokens): return last
class GeneratorParams:
    guided = False
    def __init__(self, model): pass
    def set_search_options(self, **options): pass
    def set_guidance(self, kind, data):
        assert kind == 'json_schema' and json.loads(data)
        self.guided = True
        $Extra
class Generator:
    def __init__(self, model, params):
        global last
        last = '$Answer' if params.guided else '$Control'
        self.done = False
    def append_tokens(self, tokens): pass
    def is_done(self): return self.done
    def generate_next_token(self): self.done = True
    def get_next_tokens(self): return [0]
"@)
            $previous = $env:PYTHONPATH
            $env:PYTHONPATH = $root
            try {
                $out = @(& $python $smokeScript --fixture $fixtureScript 2>&1 | ForEach-Object { "$_" }) -join "`n"
                [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out }
            } finally { $env:PYTHONPATH = $previous }
        }
    }
    It 'prints the sentinel for the one answer the schema allows, after a control that follows the model' {
        $run = Invoke-GuidanceSmoke -Control 'defg' -Answer '7'
        Assert-Equal 0 $run.Exit $run.Output
        Assert-Match 'genai-guidance-schema-ok 7' $run.Output
    }
    It 'goes red when the mask does nothing, as a build without guidance answers like the control (mutation)' {
        $run = Invoke-GuidanceSmoke -Control 'defg' -Answer 'defg'
        Assert-True ($run.Exit -ne 0) 'a nonzero exit'
        Assert-True ($run.Output -notmatch 'genai-guidance-schema-ok') 'no sentinel'
    }
    It 'goes red on valid JSON the schema forbids, and on a control that did not follow the model' {
        foreach ($case in @(@('defg', '8'), @('7', '7'))) {
            $run = Invoke-GuidanceSmoke -Control $case[0] -Answer $case[1]
            Assert-True ($run.Exit -ne 0) "$($case -join ' / '): nonzero exit"
            Assert-True ($run.Output -notmatch 'genai-guidance-schema-ok') "$($case -join ' / '): no sentinel"
        }
    }
    It 'goes red when set_guidance refuses, as an unsupported build does' {
        $run = Invoke-GuidanceSmoke -Control 'defg' -Answer '7' -Extra "raise RuntimeError('guidance is unavailable')"
        Assert-True ($run.Exit -ne 0) 'a nonzero exit'
        Assert-Match 'guidance is unavailable' $run.Output
    }
}
