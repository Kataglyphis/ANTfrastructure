#requires -Version 7.0
# Invoke-BkWarm.ps1 relaunches via `pwsh -File` so -BuildArgs like '-ResumeFrom' bind by name; each case runs in a child pwsh.

function Invoke-BkWarmForwardingFixture {
    param([Parameter(Mandatory)][scriptblock]$BuildBody, [Parameter(Mandatory)][scriptblock]$Body,
        [Parameter(Mandatory)][string]$Name, [string[]]$BuildArguments = @())
    $fixtureBody = $Body
    Invoke-InTestDir { param($dir)
        $bkWarm = Join-Path $PSScriptRoot '..\host\Invoke-BkWarm.ps1'
        $marker = Join-Path $dir 'params.txt'
        $fixture = Join-Path $dir 'fake-build.ps1'
        Set-Content -LiteralPath $fixture -Encoding ASCII -Value (& $BuildBody $marker)
        $endpoint = 'file:///C:/wbt-no-such-dir-' + [guid]::NewGuid().ToString('N')
        $command = "`$env:SCCACHE_WEBDAV_ENDPOINT = '$endpoint'; & '$bkWarm' -Name '$Name' -BuildScript '$fixture'"
        if ($BuildArguments.Count) {
            $quoted = @($BuildArguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
            $command += ' -BuildArgs @(' + ($quoted -join ',') + ')'
        }
        $output = (& pwsh -NoProfile -Command $command 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $result = [pscustomobject]@{ Marker = $marker; Output = $output; ExitCode = $LASTEXITCODE }
        Assert-True (Test-Path $marker) 'the fixture build script ran'
        Assert-True ($result.ExitCode -ne 0) 'the failed build or handoff export propagates a non-zero exit'
        & $fixtureBody $result
    }.GetNewClosure()
}

Describe 'Invoke-BkWarm.ps1 argument forwarding' {
    It 'forwards -BuildArgs as named parameters (space-containing value intact), then attempts the export' {
        Invoke-BkWarmForwardingFixture -Name wbt-fwd -BuildArguments '-ResumeFrom','X','-Until','ONNX GenAI','-ScriptDir','Z' -BuildBody {
            param($marker)
            'param([string]$ResumeFrom = "", [string]$Until = "", [string]$ScriptDir = "")'
            "Set-Content -LiteralPath '$marker' -Value (`$ResumeFrom + '|' + `$Until + '|' + `$ScriptDir) -Encoding ASCII"
            'exit 0'
        } -Body { param($result)
            Assert-Equal 'X|ONNX GenAI|Z' (Get-Content -LiteralPath $result.Marker -Raw).Trim() 'all three arguments arrived NAMED, with the embedded space intact'
            Assert-Match 'Export-BuildHandoff' $result.Output 'the failure came from the export step, AFTER the build ran'
        }
    }

    It 'a failing build script aborts bk-warm before any export is attempted' {
        Invoke-BkWarmForwardingFixture -Name wbt-abort -BuildBody {
            param($marker)
            "Set-Content -LiteralPath '$marker' -Value 'ran' -Encoding ASCII"
            'exit 1'
        } -Body { param($result)
            Assert-Match '(?s)failed.*?\(exit 1\)' $result.Output 'the error names the build exit code'
            Assert-False ($result.Output -match 'Export-BuildHandoff:') 'no export attempt after a failed build'
        }
    }
}
