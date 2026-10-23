#requires -Version 7.0
# Disposable files cover directory setup and failures; container mounts and release payload acceptance remain separate gates.

Describe 'Shared build-directory initialization' {
    It 'resets literal roots and creates only the requested child directories, with a cleanup mutant' {
        Invoke-InTestDir { param($dir)
            Invoke-TestFunctionMutations -IncludeControl -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Initialize-BuildDirectory `
                -BodyArgumentList $dir -Find '-LiteralPath $directory' -Replace '-Path $directory' -Expected 'stale paths must be removed' -Body { param($root)
                    $paths = @((Join-Path $root 'work [data]'), (Join-Path $root 'other work'))
                    foreach ($path in $paths) { Write-TestFileTree -Root $path -Files @{ 'old.txt' = 'stale' } }
                    $result = @(Initialize-MutBuildDirectory -Path $paths -Empty -ChildDirectory include, lib)
                    Assert-Equal 0 $result.Count
                    foreach ($path in $paths) {
                        Assert-False (Test-Path -LiteralPath (Join-Path $path 'old.txt')) 'stale paths must be removed'
                        $children = @(Get-ChildItem -LiteralPath $path -Directory | Sort-Object Name | Select-Object -ExpandProperty Name)
                        Assert-Equal 'include|lib' ($children -join '|') 'only the requested children may remain'
                    }
                }
        }
    }

    It 'preserves existing files without Empty and creates every requested path' {
        Invoke-InTestDir -Files @{ 'existing/keep.txt' = 'retained' } -Body { param($dir)
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Initialize-BuildDirectory -BodyArgumentList $dir -Body { param($root)
                Initialize-MutBuildDirectory -Path (Join-Path $root existing), (Join-Path $root 'new directory')
                Assert-Equal retained ([IO.File]::ReadAllText((Join-Path $root 'existing/keep.txt')))
                Assert-True ([IO.Directory]::Exists((Join-Path $root 'new directory')))
            }
        }
    }

    It 'does not hide allocation or removal failures' {
        $prelude = @'
function Test-Path { $true }
function Remove-Item { throw 'fixture remove denied' }
function New-Item { throw 'fixture allocation denied' }
'@
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Initialize-BuildDirectory -Prelude $prelude -Body {
            Assert-Throws { Initialize-MutBuildDirectory -Path fixture -Empty } -MessagePattern 'fixture remove denied'
            Assert-Throws { Initialize-MutBuildDirectory -Path fixture } -MessagePattern 'fixture allocation denied'
        }
    }
}
