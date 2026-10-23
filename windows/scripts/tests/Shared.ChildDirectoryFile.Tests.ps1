#requires -Version 7.0
# Filesystem fixtures cover child selection and missing paths; installer execution and source patching remain build coverage.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsScripts.Shared.psm1')

function Assert-ChildDirectoryFileSelection {
    param([string]$Command = 'Find-ChildDirectoryFile')
    Invoke-InTestDir { param($dir)
        Write-TestFileTree -Root $dir -Files @{
            'graphene-empty\unrelated' = 'missing marker'
            'graphene-selected\meson.build' = 'source'
            'other\meson.build' = 'excluded'
            'deep\graphene-nested\meson.build' = 'excluded'
        }
        Assert-Equal (Join-Path $dir 'graphene-selected\meson.build') (& $Command -Parent $dir -DirectoryFilter 'graphene-*' -RelativePath meson.build) 'only an immediate matching directory with the marker qualifies'
        Assert-Null (& $Command -Parent $dir -DirectoryFilter 'graphene-*' -RelativePath absent.file) 'missing relative markers must not be selected'
    }.GetNewClosure()
}

Describe 'Shared child-directory file discovery' {
    It 'filters immediate directories and skips missing candidates before returning one path' { Assert-ChildDirectoryFileSelection }

    It 'keeps provider order, nested relative paths and existing directory sentinels without throwing on missing parents' {
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'b\lib\arm64\libcmt.lib' = 'b'; 'a\lib\arm64\libcmt.lib' = 'a' }
            $first = @(Get-ChildItem -Path $dir -Directory)[0].FullName
            $found = @(Find-ChildDirectoryFile -Parent $dir -RelativePath 'lib\arm64\libcmt.lib')
            Assert-Equal 1 $found.Count
            Assert-Equal (Join-Path $first 'lib\arm64\libcmt.lib') $found[0]
            Assert-Equal (Join-Path $first 'lib\arm64') (Find-ChildDirectoryFile -Parent $dir -RelativePath 'lib\arm64') 'existing directory markers keep the original Test-Path policy'
            $ErrorActionPreference = 'Stop'
            Assert-Null (Find-ChildDirectoryFile -Parent (Join-Path $dir absent) -RelativePath marker)
            $sourceModule = Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -PassThru
            Assert-True ($sourceModule.ExportedFunctions.ContainsKey('Find-ChildDirectoryFile')) 'build scripts reach the helper through the source-build module'
            Assert-Equal $found[0] (& $sourceModule { param($root) Find-ChildDirectoryFile -Parent $root -RelativePath 'lib\arm64\libcmt.lib' } $dir)
        }
    }

    It 'detects selecting a child whose relative marker is missing' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsScripts.Shared.psm1' -FunctionName Find-ChildDirectoryFile `
            -Find 'Where-Object { Test-Path $_ }' -Replace 'Where-Object { $true }' -Body {
                Assert-Throws { Assert-ChildDirectoryFileSelection -Command Find-MutChildDirectoryFile } -MessagePattern 'only an immediate matching directory|missing relative markers'
            }
    }

    It 'keeps toolchain ARM64 success, advisory warnings and strict failure in the caller' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Toolchain.ps1' -FunctionName Invoke-Arm64StrictPolicy, Assert-Arm64ComponentLib)
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'version\lib\arm64\libcmt.lib' = 'runtime' }
            $options = @{ Label = 'ARM64 fixture'; Root = $dir; RelativePath = 'lib\arm64\libcmt.lib'; Remedy = 'install fixture component' }
            Invoke-WithEnv @{ WINDOWS_ARM64_STRICT = '1' } { Assert-Arm64ComponentLib @options }
            $options.RelativePath = 'um\arm64\kernel32.lib'
            Invoke-WithEnv @{ WINDOWS_ARM64_STRICT = '0' } {
                $warnings = @(Assert-Arm64ComponentLib @options 3>&1)
                Assert-Equal 1 $warnings.Count
                Assert-Match 'ARM64 fixture missing under .*expected <ver>\\um\\arm64\\kernel32.lib.*install fixture component.*amd64 lane unaffected' $warnings[0].Message
            }
            Invoke-WithEnv @{ WINDOWS_ARM64_STRICT = '1' } {
                Assert-Throws { Assert-Arm64ComponentLib @options } -MessagePattern 'ARM64 fixture missing under .*install fixture component'
            }
        }
    }
}
