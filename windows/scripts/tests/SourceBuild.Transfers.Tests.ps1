#requires -Version 7.0
# Fake transports cover source pin ordering and handoff verdicts; archive bytes and real downloads remain round-trip-suite coverage.

function Invoke-HandoffTransportFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $fixtureBody = $Body; $mutationFind = $Find; $mutationReplace = $Replace
    Invoke-InTestDir -Files @{ 'test.tar' = 'stale' } -Body { param($dir)
        $state = New-TestCallState @{ Code = 0; CreateOutput = $true; Body = $fixtureBody; Find = $mutationFind; Replace = $mutationReplace
            'Context' = [pscustomobject]@{ Url = 'http://fixture/bkhandoff/test.tar'; TarFile = (Join-Path $dir test.tar) } }
        Invoke-WithTestNativeCommand -Name Invoke-HandoffFixtureCurl -FixtureState $state -Implementation {
            param($state, $ArgumentList)
            if ($state.CreateOutput -and $ArgumentList -contains '-o') { [IO.File]::WriteAllText($state.Context.TarFile, 'download') }
        } -Body { param($state)
            Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName Invoke-BuildHandoffTransfer -FixtureState $state -Prelude "function Join-Path { 'Invoke-HandoffFixtureCurl' }" -Find $state.Find -Replace $state.Replace -Body $state.Body
        }
    }.GetNewClosure()
}

Describe 'Pinned primary source materialization' {
    It 'resolves each component pin before saving its source and refuses invalid pins without a save' {
        $state = New-TestCallState
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsMigraphx.Common.psm1' -FunctionName Save-MigraphxPrimarySource, Resolve-PinnedSource -FixtureState $state -Prelude @'
function Save-PinnedSource {
    param($Source, $WorkDir)
    $State.Calls.Add(@{ Source = $Source; WorkDir = $WorkDir })
    Join-Path $WorkDir $Source.Name
}
'@ -Body { param($state)
            Invoke-WithEnv @{ MIGRAPHX_WINDOWS_COMMIT = ('a' * 40); MIGRAPHX_WINDOWS_SOURCE_SHA256 = ('b' * 64); ORT_AMDGPU_EP_COMMIT = ('c' * 40); ORT_AMDGPU_EP_SOURCE_SHA256 = ('d' * 64) } {
                Assert-Equal 'C:\work\AMDMIGraphX' (Save-MutMigraphxPrimarySource -Component Migraphx -WorkDir C:\work)
                Assert-Equal 'C:\work\onnxruntime-ep-amdgpu' (Save-MutMigraphxPrimarySource -Component OrtAmdgpuEp -WorkDir C:\work)
                Assert-Equal ('https://github.com/ROCm/AMDMIGraphX/archive/' + ('a' * 40) + '.tar.gz') $state.Calls[0].Source.Url
                Assert-Equal ('b' * 64) $state.Calls[0].Source.Sha256
                Assert-Equal ('https://github.com/onnxruntime/onnxruntime-ep-amdgpu/archive/' + ('c' * 40) + '.tar.gz') $state.Calls[1].Source.Url
                Assert-Equal ('d' * 64) $state.Calls[1].Source.Sha256
                $state.Calls.Clear()
                Invoke-WithEnv @{ ORT_AMDGPU_EP_SOURCE_SHA256 = '' } {
                    Assert-Throws { Save-MutMigraphxPrimarySource -Component OrtAmdgpuEp -WorkDir C:\work } -MessagePattern 'ORT_AMDGPU_EP_SOURCE_SHA256'
                }
                Invoke-WithEnv @{ MIGRAPHX_WINDOWS_COMMIT = '' } {
                    Assert-Throws { Save-MutMigraphxPrimarySource -Component Migraphx -WorkDir C:\work } -MessagePattern 'MIGRAPHX_WINDOWS_COMMIT'
                }
                Assert-Equal 0 $state.Calls.Count 'invalid pins cannot materialize a tree'
            }
        }
    }
}

Describe 'Build handoff transport' {
    It 'binds one URL and scratch namespace and fails before transport without an endpoint' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName New-BuildHandoffContext -Body {
            $context = New-MutBuildHandoffContext -Name fixture -Endpoint 'file:///C:/server' -CallerName Import-BuildHandoff
            Assert-Equal 'file:///C:/server/bkhandoff/fixture.tar' $context.Url
            Assert-Equal (Join-Path $env:TEMP handoff-fixture.tar) $context.TarFile
            Assert-Equal (Join-Path $env:TEMP handoff-fixture.list) $context.ListFile
            Assert-Throws { New-MutBuildHandoffContext -Name fixture -Endpoint ' ' -CallerName Export-BuildHandoff } -MessagePattern 'Export-BuildHandoff: no -Endpoint'
        }
    }

    It 'keeps upload/download argv, retries and nonzero verdicts exact even with a stale archive' {
        Invoke-HandoffTransportFixture -Body { param($state)
            Invoke-MutBuildHandoffTransfer -Context $state.Context -Upload
            Assert-Equal ('-sf|--retry|3|--retry-delay|5|--retry-all-errors|-T|' + $state.Context.TarFile + '|' + $state.Context.Url) ($state.Calls[0] -join '|')
            Invoke-MutBuildHandoffTransfer -Context $state.Context
            Assert-True (Test-Path -LiteralPath $state.Context.TarFile)
            Assert-Equal '-o' $state.Calls[1][6]
            $state.Code = 12
            Assert-Throws { Invoke-MutBuildHandoffTransfer -Context $state.Context } -MessagePattern 'download.*failed - did the warm solve run'
            Assert-Throws { Invoke-MutBuildHandoffTransfer -Context $state.Context -Upload } -MessagePattern 'upload.*failed \(exit 12\)'
            $state.Code = 0; $state.CreateOutput = $false
            Remove-Item -LiteralPath $state.Context.TarFile
            Assert-Throws { Invoke-MutBuildHandoffTransfer -Context $state.Context } -MessagePattern 'download.*failed'
        }
    }

    It 'detects a download verdict that accepts a failed fetch because an archive already exists' {
        Invoke-HandoffTransportFixture -Find '$code -ne 0 -or -not (Test-Path $Context.TarFile)' -Replace '-not (Test-Path $Context.TarFile)' -Body { param($state)
            $state.Code = 8; $state.CreateOutput = $false
            Assert-Throws {
                Assert-Throws { Invoke-MutBuildHandoffTransfer -Context $state.Context } -MessagePattern 'download.*failed'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }
}
