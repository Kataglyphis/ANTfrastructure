#requires -Version 7.0
# Tests the shared AST wiring gate; it does not execute a consumer build.

function Invoke-CmakeWiringFixture {
    param([scriptblock]$Body)
    $gate = Join-Path (Get-RepoRoot) 'shared/windows/tests/Test-CmakeUvProjectWiring.ps1'
    Invoke-InTestDir { param($dir) & $Body $gate (Join-Path $dir 'Build-Windows.ps1') }
}

Describe 'shared CMake uv project wiring' {
    It 'accepts both consumer entry points with slash or backslash paths' {
        Invoke-CmakeWiringFixture { param($gate, $file)
            foreach ($command in @('Invoke-CmakeFormatStep', 'Initialize-UvVenvPython')) {
                foreach ($path in @('third_party/ANTfrastructure/quality/cmake-format', 'third_party\ANTfrastructure\quality\cmake-format')) {
                    $text = '$project = Join-Path $workspace ' + "'$path'`n" + $command + ' -WorkspacePath $workspace -UvProjectPath $project'
                    Set-Content -LiteralPath $file -Value $text
                    & $gate -ScriptPath $file -CommandName $command
                }
            }
        }
    }

    It 'rejects malformed scripts, missing or legacy arguments and incorrect project assignments' {
        Invoke-CmakeWiringFixture { param($gate, $file)
            $good = @'
$project = Join-Path $workspace 'third_party/ANTfrastructure/quality/cmake-format'
Invoke-CmakeFormatStep -WorkspacePath $workspace -UvProjectPath $project
'@
            $cases = @(
                @{ Find = '-UvProjectPath $project'; Replace = ''; Error = 'UvProjectPath' },
                @{ Find = '-UvProjectPath $project'; Replace = '-RequirementsPath $project'; Error = 'UvProjectPath' },
                @{ Find = '-UvProjectPath $project'; Replace = '-UvProjectPath $project -RequirementsPath old'; Error = 'UvProjectPath' },
                @{ Find = 'quality/cmake-format'; Replace = 'linux/scripts/cmake-format.requirements.txt'; Error = 'hub cmake-format project' },
                @{ Find = 'Join-Path $workspace'; Replace = 'Join-Path $different'; Error = 'WorkspacePath' },
                @{ Find = 'Invoke-CmakeFormatStep'; Replace = 'if ('; Error = 'parse' },
                @{ Find = 'Invoke-CmakeFormatStep'; Replace = '$project = "stale"' + "`n" + 'Invoke-CmakeFormatStep'; Error = 'one preceding assignment' }
            )
            foreach ($case in $cases) {
                $mutant = Update-TestLiteralText -Text $good -Find $case.Find -Replace $case.Replace
                Set-Content -LiteralPath $file -Value $mutant
                Assert-Throws { & $gate -ScriptPath $file -CommandName Invoke-CmakeFormatStep } -MessagePattern $case.Error
            }
        }
    }
}
