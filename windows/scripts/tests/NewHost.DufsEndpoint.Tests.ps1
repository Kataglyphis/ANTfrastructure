#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Install-NewHost dufs endpoint' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Install-NewHost.ps1' -FunctionName 'Start-DufsEndpoint', 'Invoke-DufsChange')
    $script:dufsStarts = [System.Collections.Generic.List[object]]::new()
    $script:dufsMessages = [System.Collections.Generic.List[string]]::new()
    function Test-NetConnection { [pscustomobject]@{ TcpTestSucceeded = $false } }
    function Write-HostMaintenanceMessage { param([string]$Message) $script:dufsMessages.Add($Message) }
    function Invoke-DufsCase {
        param([bool]$ReportOnly, [scriptblock]$Body)
        $check = $Body
        Invoke-InTestDir {
            param($dir)
            $script:dufsStarts.Clear()
            $script:ReportOnly = $ReportOnly
            $script:SccacheCacheDir = Join-Path $dir 'cache'
            $script:SccachePort = '18321'
            $script:DufsExtraArgs = '--allow-upload'
            Start-DufsEndpoint -Executable 'dufs.exe'
            & $check
        }
    }

    It 'does not create a cache directory or launch dufs in report mode' {
        Invoke-WithTestFunction -Name Start-Process -Definition { throw 'report mode launched dufs' } -Body {
            Invoke-DufsCase -ReportOnly $true -Body {
                Assert-False (Test-Path $script:SccacheCacheDir)
                Assert-Equal 0 $script:dufsStarts.Count
            }
        }
    }

    It 'starts the executable in a hidden window when no server listens' {
        Invoke-WithTestFunction -Name Start-Process -Definition {
            param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle)
            $script:dufsStarts.Add([pscustomobject]@{ FilePath = $FilePath; Args = $ArgumentList; WindowStyle = $WindowStyle })
        } -Body {
            Invoke-WithTestFunction -Name Start-Sleep -Definition { param([int]$Seconds) } -Body {
                Invoke-DufsCase -ReportOnly $false -Body {
                    Assert-True (Test-Path $script:SccacheCacheDir)
                    Assert-Equal 1 $script:dufsStarts.Count
                    Assert-Equal 'dufs.exe' $script:dufsStarts[0].FilePath
                    Assert-Equal 'Hidden' $script:dufsStarts[0].WindowStyle
                    Assert-Equal "$($script:SccacheCacheDir),--allow-upload,-p,18321" ($script:dufsStarts[0].Args -join ',')
                }
            }
        }
    }

    It 'applies a needed dufs change only outside report mode and reports each state' {
        $script:dufsChanges = 0
        $script:dufsMessages.Clear()
        $script:ReportOnly = $true
        Invoke-DufsChange -Needed $true -Would 'would set' -Doing 'setting' -Target 'endpoint' -Already 'endpoint set' `
            -Apply { $script:dufsChanges++ }
        Assert-Equal 0 $script:dufsChanges 'report mode does not apply'
        Assert-Equal 'dufs       : would set endpoint' $script:dufsMessages[0] 'report text'
        $script:ReportOnly = $false
        Invoke-DufsChange -Needed $true -Would 'would set' -Doing 'setting' -Target 'endpoint' -Already 'endpoint set' `
            -Apply { $script:dufsChanges++ }
        Assert-Equal 1 $script:dufsChanges 'live change applies once'
        Assert-Equal 'dufs       : setting endpoint' $script:dufsMessages[1] 'live text'
        Invoke-DufsChange -Needed $false -Would 'would set' -Doing 'setting' -Target 'endpoint' -Already 'endpoint set' `
            -Apply { throw 'unchanged endpoint was applied' }
        Assert-Equal 'dufs       : endpoint set' $script:dufsMessages[2] 'already set text'
    }
}
