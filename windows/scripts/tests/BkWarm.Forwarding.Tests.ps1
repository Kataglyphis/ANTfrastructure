#requires -Version 7.0
# Tests for bk-warm.ps1 — the WARM-solve payload wrapper (build + WebDAV
# handoff export, see docs/windows-builds.md § BuildKit/containerd lane). The
# load-bearing detail: it relaunches the build script via `pwsh -File` so that
# -BuildArgs elements like '-ResumeFrom' bind as NAMED parameters (array
# splatting binds strictly by position and dies on leading-dash values). Each
# case runs bk-warm in a CHILD pwsh because it legitimately calls `exit` /
# throws — in-process it would tear down the test runner. The child gets its
# SCCACHE_WEBDAV_ENDPOINT inside the -Command string, so no test-process env
# mutation is needed. The fixture build script writes its bound parameters to
# a file, which is the proof the forwarding survived both hops (including an
# -Until value containing a space).

Describe 'bk-warm.ps1 argument forwarding' {

    It 'forwards -BuildArgs as named parameters (space-containing value intact), then attempts the export' {
        Invoke-InTestDir { param($dir)
            $bkWarm = Join-Path $PSScriptRoot '..\bk-warm.ps1'
            $outFile = Join-Path $dir 'params.txt'
            # Fixture build script: records its NAMED parameters, exits green.
            $fixture = Join-Path $dir 'fake-build.ps1'
            Set-Content -LiteralPath $fixture -Encoding ASCII -Value @(
                'param([string]$ResumeFrom = "", [string]$Until = "", [string]$ScriptDir = "")',
                "Set-Content -LiteralPath '$outFile' -Value (`$ResumeFrom + '|' + `$Until + '|' + `$ScriptDir) -Encoding ASCII",
                'exit 0'
            )
            # A syntactically valid but dead endpoint: the build must RUN, then
            # the Export-BuildHandoff step must fail (nothing under the default
            # roots is newer than bk-warm's start, and even if something were,
            # the PUT to this endpoint cannot succeed). That failing export is
            # the proof bk-warm actually reached its handoff step.
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
            $bkWarm = Join-Path $PSScriptRoot '..\bk-warm.ps1'
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
            # (?s) + .*?: the child pwsh's ConciseView wraps the message across
            # decorated lines ("failed\n | (exit 1)"), so the two halves of the
            # error may be separated by newline + gutter characters.
            Assert-Match '(?s)failed.*?\(exit 1\)' $out 'the error names the build exit code'
            Assert-False ($out -match 'Export-BuildHandoff:') 'no export attempt after a failed build'
        }
    }
}
