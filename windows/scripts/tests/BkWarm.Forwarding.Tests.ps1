#requires -Version 7.0
# Invoke-BkWarm.ps1 relaunches via `pwsh -File` so -BuildArgs like '-ResumeFrom' bind by name; each case runs in a child pwsh.

Describe 'Invoke-BkWarm.ps1 argument forwarding' {

    It 'forwards -BuildArgs as named parameters (space-containing value intact), then attempts the export' {
        Invoke-InTestDir { param($dir)
            $bkWarm = Join-Path $PSScriptRoot '..\host\Invoke-BkWarm.ps1'
            $outFile = Join-Path $dir 'params.txt'
            # Fixture build script: records its NAMED parameters, exits green.
            $fixture = Join-Path $dir 'fake-build.ps1'
            Set-Content -LiteralPath $fixture -Encoding ASCII -Value @(
                'param([string]$ResumeFrom = "", [string]$Until = "", [string]$ScriptDir = "")',
                "Set-Content -LiteralPath '$outFile' -Value (`$ResumeFrom + '|' + `$Until + '|' + `$ScriptDir) -Encoding ASCII",
                'exit 0'
            )
            # A dead endpoint: the failing handoff export proves bk-warm ran the build and reached it.
            $endpoint = 'file:///C:/wbt-no-such-dir-' + [guid]::NewGuid().ToString('N')
            $cmd = "`$env:SCCACHE_WEBDAV_ENDPOINT = '$endpoint'; " +
                "& '$bkWarm' -Name 'wbt-fwd' -BuildScript '$fixture' " +
                "-BuildArgs @('-ResumeFrom','X','-Until','ONNX GenAI','-ScriptDir','Z')"
            $out = (& pwsh -NoProfile -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $exit = $LASTEXITCODE

            Assert-True (Test-Path $outFile) 'the fixture build script ran'
            Assert-Equal 'X|ONNX GenAI|Z' (Get-Content -LiteralPath $outFile -Raw).Trim() `
                'all three arguments arrived NAMED, with the embedded space intact'
            Assert-True ($exit -ne 0) 'bk-warm exits non-zero when the export step fails'
            Assert-Match 'Export-BuildHandoff' $out 'the failure came from the export step, AFTER the build ran'
        }
    }

    It 'a failing build script aborts bk-warm before any export is attempted' {
        Invoke-InTestDir { param($dir)
            $bkWarm = Join-Path $PSScriptRoot '..\host\Invoke-BkWarm.ps1'
            $marker = Join-Path $dir 'ran.txt'
            $fixture = Join-Path $dir 'fake-build.ps1'
            Set-Content -LiteralPath $fixture -Encoding ASCII -Value @(
                "Set-Content -LiteralPath '$marker' -Value 'ran' -Encoding ASCII",
                'exit 1'
            )
            $cmd = "`$env:SCCACHE_WEBDAV_ENDPOINT = 'file:///C:/wbt-unused'; " +
                "& '$bkWarm' -Name 'wbt-abort' -BuildScript '$fixture'"
            $out = (& pwsh -NoProfile -Command $cmd 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $exit = $LASTEXITCODE

            Assert-True (Test-Path $marker) 'the fixture ran before failing'
            Assert-True ($exit -ne 0) 'bk-warm propagates the build failure as a non-zero exit'
            # (?s): the child's ConciseView can wrap the message across decorated lines.
            Assert-Match '(?s)failed.*?\(exit 1\)' $out 'the error names the build exit code'
            Assert-False ($out -match 'Export-BuildHandoff:') 'no export attempt after a failed build'
        }
    }
}
