#requires -Version 7.0
# Stubbed execution covers compiled-path membership; it does not run clang-tidy or its parallel worker.

function New-ClangCompiledPathFixture {
    param([string]$Root)
    Write-TestFileTree -Root $Root -Files @{ 'src/MiXeD.cpp' = 'int fixture();' }
    $state = New-TestCallState @{ Root = $Root; Db = (Join-Path $Root compile_commands.json); File = (Join-Path $Root 'src/MiXeD.cpp'); DbText = '' }
    $spelled = (Join-Path $Root 'src/sub/../MiXeD.cpp').ToUpperInvariant()
    $entries = @(@{ file = $null }, @{ file = '' }, @{ file = $spelled }, @{ file = $spelled })
    $state.DbText = ConvertTo-Json -InputObject $entries
    [IO.File]::WriteAllText($state.Db, $state.DbText)
    $prelude = @'
function Get-Command { param($Name, $ErrorAction); [pscustomobject]@{ Source = 'fixture-clang-tidy' } }
function Get-CompileCommandsDatabase { param($Context, $BuildRoot); $State.Db }
function Get-ProjectCppFiles { param($WorkspacePath); $State.File }
function Test-IsCxxModuleTranslationUnit { param($Content, $Pattern); $false }
function Get-ClangTidyNonModuleFiles { param($Context, $TidyFiles, $ModuleImportPattern); $TidyFiles }
function Write-BuildLog { param($Context, $Message) }
function Invoke-BuildExternal { param($Context, $File, $Parameters); $State.Calls.Add(@{ File = $File; Arguments = $Parameters }) }
'@
    @{ ScriptPath = 'windows/scripts/modules/WindowsClang.Common.psm1'; FunctionName = 'Invoke-ClangTidyFixStep'; Prelude = $prelude; FixtureState = $state }
}

Describe 'Clang compiled-path collection' {
    It 'retains normalized case-insensitive membership, ignores empty entries and accepts an empty database, with a comparer fault control' {
        Invoke-TestFunctionMutations -ModuleArgumentsFactory ${function:New-ClangCompiledPathFixture} `
            -Find '[System.StringComparer]::OrdinalIgnoreCase' -Replace '[System.StringComparer]::Ordinal' -Expected 'normalized case-insensitive compiled membership' -IncludeControl -Body {
                param($state)
                [IO.File]::WriteAllText($state.Db, $state.DbText)
                $state.Calls.Clear()
                $options = @{ Context = [pscustomobject]@{}; WorkspacePath = $state.Root; BuildRoot = $state.Root; SourceSubdirectory = 'src'; ThrottleLimit = 1 }
                Invoke-MutClangTidyFixStep @options
                Assert-Equal 1 $state.Calls.Count 'normalized case-insensitive compiled membership'
                Assert-Equal 'fixture-clang-tidy' $state.Calls[0].File
                Assert-Equal $state.File $state.Calls[0].Arguments[-1] 'the original source spelling reaches the tool once'
                [IO.File]::WriteAllText($state.Db, '[]')
                $state.Calls.Clear()
                Invoke-MutClangTidyFixStep @options
                Assert-Equal 0 $state.Calls.Count 'an empty database contains no compiled files'
            }
    }
}
