#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local text fixtures cover patch semantics and diagnostics, not real upstream source builds.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1') -Force -DisableNameChecking

function Invoke-WithPatchFile {
    param([AllowEmptyString()][string]$InitialText, [scriptblock]$Body, [string]$Name = 'source with spaces.cpp')
    $fixtureBody = $Body
    Invoke-InTestDir { param($dir)
        $path = Join-Path $dir $Name
        [IO.File]::WriteAllText($path, $InitialText)
        & $fixtureBody $path $dir
    }
}

function Assert-QuietPatchVerdict {
    param([scriptblock]$Apply, [bool]$Expected)
    $records = @(& $Apply *>&1)
    Assert-Equal 1 $records.Count
    Assert-True ($records[0] -is [bool])
    Assert-Equal $Expected $records[0]
}

Describe 'Source patches with caller-owned diagnostics' {
    It 'preserves regex already-applied, guard and assertion policies when quiet' {
        Invoke-WithPatchFile -InitialText 'old token' -Body { param($path)
            Assert-True (Invoke-InlineRegexPatch -Path $path -Pattern old -Replacement new -Quiet)
            Assert-QuietPatchVerdict -Expected $true -Apply { Invoke-InlineRegexPatch -Path $path -Pattern old -Replacement new -SkipIfMatch '^new' -Quiet }
            Assert-False (Invoke-InlineRegexPatch -Path $path -Pattern token -Replacement gone -Guard missing -Quiet)
            Assert-Equal 'new token' ([IO.File]::ReadAllText($path))
        }
    }

    It 'retains the case-insensitive no-change contract without rewriting the file' {
        Invoke-SourceFileDiagnosticCase -InitialText OLD -ExpectedText OLD -Changed $false `
            -Transform { param($text) $text.ToLowerInvariant() }
    }

}

Describe 'Shared source patch consumers' {
    It 'keeps keyword and Ninja patching idempotent with the original diagnostic and whitespace policy' {
        $cases = @(
            @{ Name = 'keywords.cpp'; Input = "if (a or b and not c) word_or;`r`n";
                Expected = "if (a || b && ! c) word_or;`r`n"; Message = 'Patched keyword alternatives in:';
                Apply = { param($path) Edit-CppKeywordAlternatives -Path $path } },
            @{ Name = 'build.ninja'; Input = "  FLAGS = /WX  /O2`r`n  KEEP = a  b`r`n";
                Expected = " FLAGS = /O2`r`n  KEEP = a  b`r`n"; Message = 'Patched build.ninja for clang-cl compatibility:';
                Apply = { param($path) Update-NinjaFile -NinjaFile $path -StripPatterns @('/WX') } }
        )
        foreach ($case in $cases) {
            Invoke-WithPatchFile -InitialText $case.Input -Name $case.Name -Body { param($path, $dir)
                $records = @(& $case.Apply $path *>&1)
                Assert-Equal 1 $records.Count
                Assert-Match $case.Message $records[0]
                Assert-Equal $case.Expected ([IO.File]::ReadAllText($path))
                Assert-Equal 0 @(& $case.Apply $path *>&1).Count
                Assert-Equal 0 @(& $case.Apply (Join-Path $dir 'absent') *>&1).Count
            }
        }
    }

    It 'keeps IREE egg-info files across repeated configure passes without warning on a no-op' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-IreeFromSource.ps1' -FunctionName Edit-IreeCleanEggInfo)
        Invoke-InTestDir { param($dir)
            foreach ($part in 'compiler', 'runtime') {
                $null = New-Item -ItemType Directory -Path (Join-Path $dir $part)
                [IO.File]::WriteAllText((Join-Path $dir $part 'setup.py'), 'shutil.rmtree(d, ignore_errors=True)')
            }
            $records = @(& { Edit-IreeCleanEggInfo -BuildDir $dir } *>&1)
            Assert-Equal 2 $records.Count
            Assert-Equal 'print(f"kataglyphis: keeping fresh egg-info {d}")' ([IO.File]::ReadAllText((Join-Path $dir 'compiler/setup.py')))
            Assert-Equal 0 @(& { Edit-IreeCleanEggInfo -BuildDir $dir } *>&1).Count
        }
    }
}

Describe 'GStreamer OpenCV 5 source transformation' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -FunctionName ConvertTo-GstOpenCv5Text)
    It 'adds each required header once after the first include and remains idempotent' {
        $text = "#include <opencv2/core.hpp>`r`n#include <opencv2/imgproc.hpp>`r`nCascadeClassifier c; contourArea(); findChessboardCorners(); ftello(f); fseeko(f);"
        $patched = ConvertTo-GstOpenCv5Text -Text $text
        foreach ($header in 'xobjdetect', 'geometry', 'calib', 'objdetect') {
            Assert-Equal 1 ([regex]::Matches($patched, "#include <opencv2/$header.hpp>")).Count
        }
        Assert-Match '_ftelli64\(f\); _fseeki64\(f\);' $patched
        Assert-True ($patched.IndexOf('geometry.hpp') -lt $patched.IndexOf('imgproc.hpp'))
        Assert-Equal $patched (ConvertTo-GstOpenCv5Text -Text $patched)
        Assert-Equal '' (ConvertTo-GstOpenCv5Text -Text '')
    }
}

Describe 'Source patch mutation proofs' {
    $patchSource = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1'))
    $gstSource = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/build/Build-GstreamerFromSource.ps1'))

    It 'detects a quiet callback patch that still emits a warning' {
        Invoke-WithFunctionModule -Text $patchSource -FunctionName Read-SourcePatchInput, Save-SourcePatchText, Edit-SourceFile `
            -Find 'if (-not $Quiet) { Write-Warning $WarnMessage }' -Replace 'Write-Warning $WarnMessage' -Body {
            Invoke-WithPatchFile -InitialText unchanged -Body { param($path)
                Assert-Throws {
                    Assert-QuietPatchVerdict -Expected $false -Apply { Edit-MutSourceFile -Path $path -Transform { param($text) $text } -Quiet }
                } -MessagePattern 'Assert-Equal'
            }
        }
    }

    It 'detects replacing every include instead of inserting one copy of the required header' {
        Invoke-WithFunctionModule -Text $gstSource -FunctionName ConvertTo-GstOpenCv5Text `
            -Find '$include.Replace($Text, "`${1}#include <$hdr>`n", 1)' -Replace '$include.Replace($Text, "`${1}#include <$hdr>`n")' -Body {
            $text = "#include <opencv2/core.hpp>`n#include <opencv2/imgproc.hpp>`ncontourArea();"
            $mutated = ConvertTo-MutGstOpenCv5Text -Text $text
            Assert-Throws { Assert-Equal 1 ([regex]::Matches($mutated, '#include <opencv2/geometry.hpp>')).Count } -MessagePattern 'Assert-Equal'
        }
    }
}

function Get-LitertLmPatchTransform {
    param([string]$PathVariable, [string]$TransformCommand = '')
    $tree = Get-TestScriptAst -ScriptPath 'windows/scripts/build/Build-LitertLmFromSource.ps1'
    $sites = @(Get-TestAstCommands -Ast $tree -Name Edit-SourceFile | Where-Object {
            (Get-TestCommandArguments -Command $_)['Path'] -eq $PathVariable -and
            (-not $TransformCommand -or @(Get-TestAstCommands -Ast $_ -Name $TransformCommand).Count -gt 0)
        })
    Assert-Equal 1 $sites.Count
    $arguments = Get-TestCommandArguments -Command $sites[0] -AsAst
    Assert-True ($arguments.Transform -is [Management.Automation.Language.ScriptBlockExpressionAst])
    $guard = ''
    if ($arguments.ContainsKey('Guard')) {
        Assert-True ($arguments.Guard -is [Management.Automation.Language.StringConstantExpressionAst])
        $guard = $arguments.Guard.Value
    }
    [pscustomobject]@{ Transform = $arguments.Transform.ScriptBlock.GetScriptBlock(); Guard = $guard }
}

Describe 'LiteRT-LM source patch callbacks' {
    It 'preserves the logging-target guard while converting only its compile and propagation settings' {
        $patch = Get-LitertLmPatchTransform -PathVariable '$utilCmake'
        $inputText = "add_litertlm_library(runtime_util_logging INTERFACE)`n" +
            "target_include_directories(runtime_util_logging INTERFACE include)`n" +
            'target_link_libraries(runtime_util_logging INTERFACE dependency)'
        $expected = "add_litertlm_library(runtime_util_logging STATIC`n  logging.cc`n)`n" +
            "target_include_directories(runtime_util_logging PUBLIC include)`n" +
            'target_link_libraries(runtime_util_logging PUBLIC dependency)'
        Assert-Equal $expected (& $patch.Transform $inputText)
        Invoke-WithPatchFile -InitialText $inputText -Body { param($path)
            Assert-True (Edit-SourceFile -Path $path -Guard $patch.Guard -Transform $patch.Transform -Quiet)
            Assert-False (Edit-SourceFile -Path $path -Guard $patch.Guard -Transform $patch.Transform -Quiet)
            Assert-Equal $expected ([IO.File]::ReadAllText($path))
        }
        $unrelated = $inputText.Replace('runtime_util_logging INTERFACE)', 'other_target INTERFACE)')
        Invoke-WithPatchFile -InitialText $unrelated -Body { param($path)
            Assert-False (Edit-SourceFile -Path $path -Guard $patch.Guard -Transform $patch.Transform -Quiet)
            Assert-Equal $unrelated ([IO.File]::ReadAllText($path))
        }
    }

    It 'forwards caller text and source directory through the shared engine edit cycle' {
        $patch = Get-LitertLmPatchTransform -PathVariable '$engineCmake' -TransformCommand Add-LiteRtLmV014OrphanSources
        $prelude = @'
param([string]$SourceDir)
function Add-LiteRtLmV014OrphanSources {
    param([string]$EngineCmakeText, [string]$SourceDir)
    "$EngineCmakeText|$SourceDir"
}
'@
        Invoke-WithPatchFile -InitialText engine -Body { param($path, $dir)
            $module = Import-FunctionModule -Dir $dir -Text ('function Invoke-EngineFixture {' + $patch.Transform.ToString() + '}') `
                -Prelude $prelude -Prefix Fixture -ArgumentList @('fixture source with spaces')
            try {
                Assert-True (Edit-SourceFile -Path $path -Transform ${function:Invoke-FixtureEngineFixture} -Require -Quiet)
                Assert-Equal 'engine|fixture source with spaces' ([IO.File]::ReadAllText($path))
            } finally { Remove-Module $module -Force }
        }
    }
}
