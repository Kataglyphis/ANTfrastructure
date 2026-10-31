#requires -Version 7.0
# Emulates only the runner's pwsh tail; native Pester and the shell flags GitHub passes are out of scope.

Describe 'Reusable Pester action exit status' {
    It 'ignores an exit code a passing suite leaked from its own native calls' {
        $actionDir = Join-Path (Get-RepoRoot) '.github/actions/run-pester-suite'
        $yaml = Get-Content -Raw -LiteralPath (Join-Path $actionDir 'action.yml')
        $block = [regex]::Match($yaml, '(?ms)^      run: \|\r?\n(.*?)(?=^\S|\z)').Groups[1].Value
        $body = (($block -split '\r?\n') | ForEach-Object { if ($_.Length -ge 8) { $_.Substring(8) } else { '' } }) -join "`n"
        $body = $body.Replace('${{ inputs.version }}', '3.4.0').Replace('${{ inputs.path }}', 'fixture.Tests.ps1')
        Assert-Match 'Invoke-Pester' $body
        $prelude = @(
            "`$env:GITHUB_ACTION_PATH = $(ConvertTo-TestPwshLiteral -Value $actionDir)"
            'function Import-Module { param($Name, $RequiredVersion, $ErrorAction) }'
            'function Install-PinnedPowerShellModule { param($Name, $Version, [switch]$SkipPublisherCheck) }'
            'function Invoke-Pester { param($Path, [switch]$PassThru, [switch]$Quiet); $global:LASTEXITCODE = 1; [pscustomobject]@{ TotalCount = 2; PassedCount = 2; FailedCount = 0; TestResult = @() } }'
        ) -join "`n"
        $tail = 'if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }'
        $probe = Invoke-TestPwshProbe -Source ($prelude + "`n" + $body + "`n" + $tail)
        Assert-Equal 0 $probe.ExitCode $probe.Output
        Assert-Match 'TOTAL=2 PASSED=2 FAILED=0' $probe.Output
    }
}
