#requires -Version 7.0
# Filesystem fixtures inspect SDK/MSVC selection; they do not compile, link or probe an installed image.

function Invoke-Arm64LibraryFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $tree = Get-TestScriptAst -ScriptPath 'windows/scripts/diagnostics/Test-Arm64Prereqs.ps1'
    $assignments = @(foreach ($variable in '$sdkArm', '$msvcArm') {
        $nodes = @($tree.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $variable
        }.GetNewClosure(), $true))
        Assert-Equal 1 $nodes.Count "one $variable assignment"
        $nodes[0].Extent.Text
    })
    $text = 'function Get-PrerequisiteLibrary { param($sdkLibRoot, $vcToolsRoots) ' + ($assignments -join ";`n") + '; [pscustomobject]@{ Sdk = $sdkArm; Msvc = $msvcArm } }'
    $shared = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1'
    Invoke-WithFunctionModule -Text $text -Find $Find -Replace $Replace -Prelude 'param($SharedModule); Import-Module $SharedModule -DisableNameChecking' -ArgumentList @($shared) -Body $Body
}

function Assert-Arm64LibraryFixture {
    Invoke-InTestDir -Files @{
        'sdk/1/unrelated.txt' = 'missing arm64 marker'
        'sdk/2/um/arm64/kernel32.lib' = 'sdk arm64'
        'sdk/2/um/x64/kernel32.lib' = 'host decoy'
        'vs-a/BuildTools/MSVC/1/lib/x64/libcmt.lib' = 'host decoy'
        'vs-b/BuildTools/MSVC/2/lib/arm64/libcmt.lib' = 'msvc arm64'
    } -Body { param($dir)
        $result = Get-MutPrerequisiteLibrary -sdkLibRoot (Join-Path $dir sdk) -vcToolsRoots @((Join-Path $dir vs-a), (Join-Path $dir vs-b))
        Assert-Equal (Join-Path $dir 'sdk/2/um/arm64/kernel32.lib') $result.Sdk 'the SDK selection must retain arm64'
        Assert-Equal (Join-Path $dir 'vs-b/BuildTools/MSVC/2/lib/arm64/libcmt.lib') $result.Msvc 'the MSVC control must retain arm64'
        $absent = Get-MutPrerequisiteLibrary -sdkLibRoot (Join-Path $dir missing) -vcToolsRoots @((Join-Path $dir vs-a))
        Assert-Null $absent.Sdk
        Assert-Null $absent.Msvc
    }
}

Describe 'ARM64 prerequisite shared library lookup' {
    It 'keeps SDK version search, ordered MSVC roots and missing-arm64 controls' {
        Invoke-Arm64LibraryFixture -Body { Assert-Arm64LibraryFixture }
    }

    It 'rejects a drift to the host SDK architecture even when the host library exists' {
        Invoke-Arm64LibraryFixture -Find 'um\arm64\kernel32.lib' -Replace 'um\x64\kernel32.lib' -Body {
            Assert-Throws { Assert-Arm64LibraryFixture } -MessagePattern 'SDK selection must retain arm64'
        }
    }
}
