#requires -Version 7.0
# Filesystem fixtures cover leaf module precedence and failure; importing each production module remains closure-suite coverage.

Describe 'Source-build leaf module resolution' {
    It 'preserves repository precedence, container fallback and explicit directories while rejecting missing files' {
        Invoke-InTestDir -Files @{ 'modules\Leaf.psm1' = 'repository'; 'ortmods\Leaf.psm1' = 'mounted'; 'leafmods\Leaf.psm1' = 'leaf' } -Body { param($dir)
            Assert-Equal (Join-Path $dir 'modules\Leaf.psm1') (Resolve-SourceBuildLeafModule -AssetRoot $dir -Name Leaf.psm1)
            Remove-Item -LiteralPath (Join-Path $dir 'modules\Leaf.psm1')
            Assert-Equal (Join-Path $dir 'ortmods\Leaf.psm1') (Resolve-SourceBuildLeafModule -AssetRoot $dir -Name Leaf.psm1)
            Assert-Equal (Join-Path $dir 'leafmods\Leaf.psm1') (Resolve-SourceBuildLeafModule -AssetRoot $dir -Name Leaf.psm1 -Directory leafmods)
            Assert-Throws { Resolve-SourceBuildLeafModule -AssetRoot $dir -Name Missing.psm1 } -MessagePattern 'Missing.psm1 is not mounted'
            Remove-Item -LiteralPath (Join-Path $dir 'ortmods\Leaf.psm1')
            $null = New-Item -ItemType Directory -Path (Join-Path $dir 'modules\Leaf.psm1')
            Assert-Throws { Resolve-SourceBuildLeafModule -AssetRoot $dir -Name Leaf.psm1 } -MessagePattern 'is not mounted'
        }
    }

    It 'detects disabling the missing-module failure' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSourceBuild.Common.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Resolve-SourceBuildLeafModule -Find 'throw "$Name is not mounted under $AssetRoot (searched $($Directory -join '', ''))"' -Replace 'return' -Body {
            Invoke-InTestDir { param($dir)
                Assert-Throws {
                    Assert-Throws { Resolve-MutSourceBuildLeafModule -AssetRoot $dir -Name Missing.psm1 } -MessagePattern 'is not mounted'
                } -MessagePattern 'expected an exception but none was thrown'
            }
        }
    }
}
