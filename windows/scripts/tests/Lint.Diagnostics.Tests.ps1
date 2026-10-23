#requires -Version 7.0
# AST fixtures check diagnostic text and traversal; source snippets are never executed.
Import-Module (Join-Path $PSScriptRoot '../modules/WindowsLint.Common.psm1') -Force -DisableNameChecking

Describe 'Shared lint traversal and diagnostics' {
    It 'retains labels, positions, ordering and distinct glued-argument diagnostics' {
        $ast = ConvertTo-TestScriptAst -Text @'
buildctl --output type=local,dest=$outDir
Invoke-Thing -Path$x
Invoke-Thing -Path($x)
'@
        $bare = @(Get-BarewordCommaAttrViolation -Ast $ast -Label fixture.ps1)
        Assert-Equal 'fixture.ps1:1: type=local,dest=$outDir' ($bare -join "`n")
        $glued = @(Get-GluedParameterViolation -Ast $ast -Label fixture.ps1)
        Assert-Equal @'
fixture.ps1:2: -Path$x (parameter name swallowed a variable -- add the space)
fixture.ps1:3: -Path($x) (argument glued to the parameter -- add the space)
'@ ($glued -join "`n")
    }

    It 'keeps switch scope boundaries and ignores boolean toggles' {
        $ast = ConvertTo-TestScriptAst -Text @'
param([switch]$Flag)
$flag = 'bad'
function Inner {
    param([switch]$Flag)
    $FLAG = 42
    $Flag = $false
}
'@
        $out = @(Get-SwitchShadowViolation -Ast $ast -Label scope.ps1)
        Assert-Equal @'
scope.ps1:2: $flag = 'bad'
scope.ps1:5: $FLAG = 42
'@ ($out -join "`n")
    }

    It 'returns no findings for empty input and for spaced, colon and native parameter syntax' {
        $empty = ConvertTo-TestScriptAst -Text ''
        foreach ($check in @('Get-BarewordCommaAttrViolation', 'Get-SwitchShadowViolation', 'Get-GluedParameterViolation')) {
            Assert-Equal 0 @(& $check -Ast $empty).Count
        }
        $valid = ConvertTo-TestScriptAst -Text @'
Get-Item -Path $x
Get-Item -Path:$x
clang-cl -Fo$file
unknown-tool -Path$x
'@
        Assert-Equal 0 @(Get-GluedParameterViolation -Ast $valid).Count
    }

    It 'detects a visitor that drops command-element checks' {
        $ast = ConvertTo-TestScriptAst -Text 'buildctl --output type=local,dest=$outDir'
        Assert-Equal 1 @(Get-BarewordCommaAttrViolation -Ast $ast).Count
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../modules/WindowsLint.Common.psm1'))
        Invoke-WithFunctionModule -Text $source -FunctionName Format-LintViolation, Invoke-LintCommandElementRule, Get-BarewordCommaAttrViolation `
            -Find '& $Rule $elements[$index] $next $Label' -Replace '$null = $elements[$index]' -Body {
                $tree = ConvertTo-TestScriptAst -Text 'buildctl --output type=local,dest=$outDir'
                Assert-Throws { Assert-Equal 1 @(Get-MutBarewordCommaAttrViolation -Ast $tree).Count } -MessagePattern 'Assert-Equal'
            }
    }
}
