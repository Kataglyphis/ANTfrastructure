#requires -Version 7.0
# Local command fixtures cover discovery and routing, not real formatter output or terminal behavior.

$script:FormattingPrelude = @'
param($State)
Set-StrictMode -Version Latest
$script:FixtureState = $State
$script:CppExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.ixx')
$script:UntrackedTreePattern = '\\(node_modules|\.pub-cache|\.dart_tool|\.gradle|\.cxx|\.cargo)\\|\\flutter\\ephemeral\\'
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'git' -and $script:FixtureState.GitAvailable) { return [pscustomobject]@{ Source = $script:FixtureState.Git } }
    if ($Name -eq 'clang-format' -and $script:FixtureState.Clang) { return [pscustomobject]@{ Source = $script:FixtureState.Clang } }
}
function Join-Path {
    param($Path, $ChildPath)
    if ($script:FixtureState.WindowsPaths) { return "${Path}\${ChildPath}" }
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
function Test-Path { param($Path) $script:FixtureState.Installed -contains $Path }
function Write-BuildLog { param($Context, $Message) $script:FixtureState.Log.Add("$Message") }
function Invoke-BuildExternal { param($Context, $File, $Parameters) $script:FixtureState.Calls.Add("$File|$($Parameters -join '|')") }
function cmd.exe { param($flag, $line) $script:FixtureState.Calls.Add("$flag|$line"); $global:LASTEXITCODE = 0 }
'@
$script:FormattingGit = @'
$mode = [IO.File]::ReadAllText("$PSScriptRoot/mode.txt")
if ($mode -eq 'throw') { throw 'git fixture failed' }
[IO.File]::WriteAllText("$PSScriptRoot/args.txt", ($args -join '|'))
[IO.File]::ReadAllLines("$PSScriptRoot/tracked.txt") | Write-Output
$global:LASTEXITCODE = if ($mode -eq 'fail') { 1 } else { 0 }
'@

function Invoke-FormattingDiscoveryFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $fixtureBody = $Body
    Invoke-InTestDir { param($dir)
        $override = Get-Variable FormattingFixtureSourceFile -Scope Global -ErrorAction SilentlyContinue
        $path = if ($override) { $override.Value } else { Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsFormatting.Common.psm1' }
        $text = [IO.File]::ReadAllText($path)
        $ast = ConvertTo-TestScriptAst -Text $text
        $present = @(Get-TestFunctionNames -Ast $ast)
        $names = @('Get-TrackedProjectFiles', 'Get-ProjectSourceFiles', 'Get-ProjectCppFiles', 'Get-ProjectDartFiles',
            'Get-ClangFormatExecutable', 'Get-ClangFormatInputs', 'Invoke-ClangFormatStep', 'Invoke-ClangFormatCheck') | Where-Object { $_ -in $present }
        $state = [pscustomobject]@{ GitAvailable = $true; Git = (Join-Path $dir 'git.ps1'); Clang = 'fixture-clang';
            Installed = @(); WindowsPaths = $true; Calls = [Collections.Generic.List[string]]::new(); Log = [Collections.Generic.List[string]]::new() }
        [IO.File]::WriteAllText($state.Git, $script:FormattingGit)
        Set-FormattingGitFixture -Dir $dir
        Invoke-WithFunctionModule -Text $text -FunctionName $names -Prelude $script:FormattingPrelude -Prefix Fmt -ArgumentList @($state) -Body $fixtureBody -BodyArgumentList @($dir, $state)
    }
}

function Invoke-FormattingFixtureModes {
    Invoke-FmtClangFormatStep -Context ([pscustomobject]@{}) -WorkspacePath 'C:\fixture'
    Invoke-FmtClangFormatCheck -Context ([pscustomobject]@{}) -WorkspacePath 'C:\fixture' -ExpectedVersion ''
}

function Set-FormattingGitFixture {
    param([string]$Dir, [string]$Mode = 'ok', [string[]]$Tracked = @(''))
    [IO.File]::WriteAllText((Join-Path $Dir 'mode.txt'), $Mode)
    [IO.File]::WriteAllLines((Join-Path $Dir 'tracked.txt'), $Tracked)
}

Describe 'Formatting discovery contracts' {
    It 'retains the distinct tracked C++ and Dart discovery policies' {
        Invoke-FormattingDiscoveryFixture { param($dir, $state)
            $cases = @(
                @{ Language = 'Cpp'; Tracked = @('src\z.cpp', 'build\generated.cpp', 'third_party\x.cpp', '_deps\x.cpp', 'vcpkg_installed\x.cpp', 'src\a.cpp', 'src\a.cpp', ' ');
                    Expected = 'src\a.cpp|src\z.cpp'; Pathspec = '*.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.ixx' },
                @{ Language = 'Dart'; Tracked = @('lib\z.dart', 'flutter\x.dart', 'rust_builder\x.dart', '.git\modules\x.dart', 'lib\a.dart', 'lib\a.dart', '_deps\kept.dart', 'vcpkg_installed\kept.dart');
                    Expected = 'lib\z.dart|lib\a.dart|lib\a.dart|_deps\kept.dart|vcpkg_installed\kept.dart'; Pathspec = '*.dart' }
            )
            foreach ($case in $cases) {
                Set-FormattingGitFixture -Dir $dir -Tracked $case.Tracked
                $files = @(& "Get-FmtProject$($case.Language)Files" -WorkspacePath 'C:\fixture')
                $expected = ($case.Expected.Split('|') | ForEach-Object { "C:\fixture\$_" }) -join '|'
                Assert-Equal $expected ($files -join '|')
                Assert-Equal "-C|C:\fixture|ls-files|$($case.Pathspec)" ([IO.File]::ReadAllText("$dir/args.txt"))
            }
        }
    }

    It 'walks C++ on absent, empty or failed git output while Dart remains tracked-only' {
        Invoke-FormattingDiscoveryFixture { param($dir, $state)
            $state.WindowsPaths = $false
            [IO.File]::WriteAllText((Join-Path $dir 'own.cpp'), 'fixture')
            foreach ($mode in @('absent', 'empty', 'fail')) {
                $state.GitAvailable = $mode -ne 'absent'
                Set-FormattingGitFixture -Dir $dir -Mode $mode -Tracked $(if ($mode -eq 'fail') { 'ghost.cpp' } else { '' })
                Assert-Equal (Join-Path $dir 'own.cpp') ((Get-FmtProjectCppFiles -WorkspacePath $dir) -join '|')
                Assert-Equal 0 @(Get-FmtProjectDartFiles -WorkspacePath $dir).Count
            }
            $state.GitAvailable = $true
            Set-FormattingGitFixture -Dir $dir -Mode throw
            Assert-Equal (Join-Path $dir 'own.cpp') ((Get-FmtProjectCppFiles -WorkspacePath $dir) -join '|')
            Assert-Throws { Get-FmtProjectDartFiles -WorkspacePath $dir } -MessagePattern 'git fixture failed'
        }
    }

    It 'uses PATH before common installations for both rewrite and check modes' {
        Invoke-FormattingDiscoveryFixture { param($dir, $state)
            Set-FormattingGitFixture -Dir $dir -Tracked 'src\own.cpp'
            $state.Installed = @('C:\Program Files\LLVM\bin\clang-format.exe', 'C:\Program Files (x86)\LLVM\bin\clang-format.exe')
            foreach ($expected in @('fixture-clang', $state.Installed[0], $state.Installed[1])) {
                $state.Calls.Clear()
                Invoke-FormattingFixtureModes
                Assert-Equal "$expected|-i|C:\fixture\src\own.cpp" $state.Calls[0]
                Assert-Equal "/c|`"$expected`" --dry-run -Werror `"C:\fixture\src\own.cpp`" >nul 2>nul" $state.Calls[1]
                $state.Clang = ''
                $state.Installed = @($state.Installed | Where-Object { $_ -ne $expected })
            }
        }
    }

    It 'keeps empty-source diagnostics distinct without invoking a formatter' {
        Invoke-FormattingDiscoveryFixture { param($dir, $state)
            Set-FormattingGitFixture -Dir $dir -Tracked ' '
            Invoke-FormattingFixtureModes
            Assert-Equal 'No C/C++ files found for clang-format.|No C/C++ files found for the clang-format check.' ($state.Log -join '|')
            Assert-Equal 0 $state.Calls.Count
        }
    }

    It 'keeps report-only missing tools advisory and mandatory tools fatal with an actionable diagnostic' {
        Invoke-FormattingDiscoveryFixture { param($dir, $state)
            $state.Clang = ''
            Invoke-FmtClangFormatCheck -Context ([pscustomobject]@{}) -WorkspacePath 'C:\fixture' -ExpectedVersion ''
            Assert-Match 'not found; skipping' ($state.Log -join '|')
            Assert-Throws { Invoke-FmtClangFormatCheck -Context ([pscustomobject]@{}) -WorkspacePath 'C:\fixture' -ExpectedVersion '' -FailOnDeviation } -MessagePattern 'format gate cannot run'
            Assert-Throws { Invoke-FmtClangFormatStep -Context ([pscustomobject]@{}) -WorkspacePath 'C:\fixture' } -MessagePattern 'not found on PATH or in common installation locations'
        }
    }
}
