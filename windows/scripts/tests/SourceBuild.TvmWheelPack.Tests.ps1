#requires -Version 7.0
# Synthetic package trees and a pack stub cover assembly verdicts; real Python wheel compatibility remains build coverage.

$script:TvmWheelSource = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsTvm.Common.psm1'))

function Invoke-TvmWheelPackFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Mode = 'one', [string]$Find = '', [string]$Replace = '')
    $sourceText = $script:TvmWheelSource
    Invoke-InTestDir { param($dir)
        $state = [pscustomobject]@{ Root = $dir; Out = (Join-Path $dir 'wheel out'); Mode = $Mode; Calls = 0; CommandLine = '' }
        $null = New-Item -ItemType Directory -Path $state.Out
        Write-TestFileTree -Root $dir -Files @{ 'source\__init__.py' = 'package'; 'native\runtime.dll' = 'native'; 'wheel out\existing.whl' = 'old' }
        $prelude = @'
param($State)
$script:packState = $State
function Invoke-ShieldedNative {
    param($Label, $CommandLine)
    $script:packState.Calls++
    $script:packState.CommandLine = $CommandLine
    if ($script:packState.Mode -eq 'fail') { throw 'fixture wheel pack failed' }
    $count = if ($script:packState.Mode -eq 'two') { 2 } elseif ($script:packState.Mode -eq 'none') { 0 } else { 1 }
    foreach ($number in 1..$count | Where-Object { $count -gt 0 }) { [IO.File]::WriteAllText((Join-Path $script:packState.Out "new-$number.whl"), 'wheel') }
    return 'pack stdout'
}
'@
        $caseBody = $Body
        Invoke-WithFunctionModule -Text $sourceText -FunctionName Write-AssembledWheelDistInfo, New-AssembledPythonWheel, Initialize-AssembledPythonPackage `
            -Prelude $prelude -ArgumentList @($state) -Find $Find -Replace $Replace -BodyArgumentList @($state, $caseBody) -Body {
                param($fixture, $action)
                $packageRoot = Join-Path $fixture.Root 'staged package'
                Initialize-MutAssembledPythonPackage -SourcePackage (Join-Path $fixture.Root 'source') -PackageRoot $packageRoot -PackageName tvm -Library @((Join-Path $fixture.Root 'native\runtime.dll'))
                $metadata = @{ Name = 'apache-tvm'; Version = '1.2.3'; PackageRoot = $packageRoot; PythonTag = 'py3'; AbiTag = 'none'; PlatformTag = 'win_arm64'
                    RequiresDist = @('apache-tvm-ffi>=0.1'); RequiresPython = '>=3.10'; Summary = 'fixture' }
                & $action $fixture $metadata
            }
    }.GetNewClosure()
}

Describe 'TVM package assembly and wheel packing' {
    It 'copies package contents and native libraries once, writes metadata and returns only the newly packed wheel' {
        Invoke-TvmWheelPackFixture -Body {
            param($state, $metadata)
            $result = @(New-MutAssembledPythonWheel -Metadata $metadata -PackExe 'C:\host python\python.exe' -OutDir $state.Out)
            Assert-Equal 1 $result.Count
            Assert-Equal (Join-Path $state.Out 'new-1.whl') $result[0]
            Assert-Equal 1 $state.Calls
            Assert-Match '^"C:\\host python\\python.exe" -m wheel pack ".*staged package" --dest-dir ".*wheel out"$' $state.CommandLine
            Assert-Equal package ([IO.File]::ReadAllText((Join-Path $metadata.PackageRoot 'tvm\__init__.py')))
            Assert-Equal native ([IO.File]::ReadAllText((Join-Path $metadata.PackageRoot 'tvm\lib\runtime.dll')))
            $distInfo = Join-Path $metadata.PackageRoot 'apache_tvm-1.2.3.dist-info'
            Assert-Match 'Requires-Dist: apache-tvm-ffi>=0.1' ([IO.File]::ReadAllText((Join-Path $distInfo 'METADATA')))
            Assert-Match 'Tag: py3-none-win_arm64' ([IO.File]::ReadAllText((Join-Path $distInfo 'WHEEL')))
            Assert-True (Test-Path -LiteralPath (Join-Path $state.Out 'existing.whl'))
        }
    }

    It 'rejects zero or multiple newly packed wheels and propagates native failures' {
        foreach ($mode in 'none', 'two', 'fail') {
            Invoke-TvmWheelPackFixture -Mode $mode -Body {
                param($state, $metadata)
                $pattern = if ($state.Mode -eq 'fail') { 'fixture wheel pack failed' } else { 'not one' }
                Assert-Throws { New-MutAssembledPythonWheel -Metadata $metadata -PackExe python.exe -OutDir $state.Out } -MessagePattern $pattern
            }
        }
    }

    It 'detects disabling the newly packed wheel cardinality check' {
        Invoke-TvmWheelPackFixture -Mode two -Find '$packed.Count -ne 1' -Replace '$false' -Body {
            param($state, $metadata)
            Assert-Throws {
                Assert-Throws { New-MutAssembledPythonWheel -Metadata $metadata -PackExe python.exe -OutDir $state.Out | Out-Null } -MessagePattern 'not one'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }
}
