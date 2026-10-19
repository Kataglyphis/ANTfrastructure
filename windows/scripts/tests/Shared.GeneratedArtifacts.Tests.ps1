#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The consumers' suite run as they run it: a child pwsh, Pester 3.4.0 (run-pester-suite's pin) and 5+, GITHUB_WORKSPACE.

$script:ArtifactsSuite = Join-Path (Get-RepoRoot) 'shared\windows\tests\Repo.GeneratedArtifacts.Tests.ps1'

# A committed repo with -Files and, unless -NoPatternFile, scripts\windows\generated-artifacts.txt holding -Patterns.
function script:New-ArtifactsRepo([string]$Dir, [string[]]$Files, [string[]]$Patterns = @(), [switch]$NoPatternFile) {
    $null = New-Item -ItemType Directory -Force -Path $Dir
    if (-not $NoPatternFile) { $Files += 'scripts/windows/generated-artifacts.txt' }
    foreach ($f in $Files) {
        $path = Join-Path $Dir $f
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $path)
        $body = if ($f -like '*generated-artifacts.txt') { $Patterns } else { 'x' }
        Set-Content -LiteralPath $path -Value $body
    }
    $identity = @('-c', 'user.email=test@example.invalid', '-c', 'user.name=Artifacts Test')
    & git -C $Dir @identity init --quiet 2>$null
    & git -C $Dir @identity add -A 2>$null
    & git -C $Dir @identity commit --quiet -m fixture 2>$null
}

# Runs the suite in a child pwsh under one Pester version; returns "<total>/<failed>" and the failure messages.
function script:Invoke-ArtifactsSuite([string]$Dir, [string]$Version, [hashtable]$Data = @{}) {
    $runner = Join-Path $Dir 'run-suite.ps1'
    Set-Content -LiteralPath $runner -Value @(
        'param($Suite, $Version, $DataJson)'
        '$data = @{}; ($DataJson | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $data[$_.Name] = @($_.Value) }'
        'Import-Module Pester -RequiredVersion $Version -DisableNameChecking 3>$null'
        'if ($Version -like "3.*") { $r = Invoke-Pester -Script @{ Path = $Suite; Parameters = $data } -PassThru -Quiet; $msg = @($r.TestResult | Where-Object { -not $_.Passed } | ForEach-Object FailureMessage) }'
        'else { $c = New-PesterConfiguration; $c.Run.Container = New-PesterContainer -Path $Suite -Data $data; $c.Run.PassThru = $true; $c.Output.Verbosity = "None"; $r = Invoke-Pester -Configuration $c; $msg = @(@($r.Failed) + @($r.FailedBlocks) | ForEach-Object { $_.ErrorRecord.Exception.Message }) }'
        '"RESULT $($r.TotalCount)/$($r.FailedCount)"; $msg | ForEach-Object { "FAIL $_" }'
    )
    $out = Invoke-WithEnv @{ GITHUB_WORKSPACE = (Join-Path $Dir 'repo') } {
        @(& pwsh -NoProfile -File $runner -Suite $script:ArtifactsSuite -Version $Version -DataJson ($Data | ConvertTo-Json -Compress) 2>&1 | ForEach-Object { "$_" })
    }
    return [pscustomobject]@{
        Result = "$(@($out | Where-Object { $_ -like 'RESULT *' }) | Select-Object -Last 1)".Replace('RESULT ', '')
        Text   = (@($out | Where-Object { $_ -like 'FAIL *' }) -join "`n")
    }
}

$script:PesterVersions = @(@(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'3.4.0' -or $_.Version -ge [version]'5.0' } |
            Sort-Object Version -Unique | ForEach-Object { "$($_.Version)" }) | Select-Object -First 1 -Last 1 | Sort-Object -Unique)

Describe 'shared Repo.GeneratedArtifacts.Tests.ps1' {

    It 'runs under Pester 3.4.0, which run-pester-suite pins, and under Pester 5+' {
        Assert-True ($script:PesterVersions.Count -ge 1) 'no Pester 3.4.0 or 5+ to run the suite with'
        Write-Host "    Pester versions: $($script:PesterVersions -join ', ')"
    }

    foreach ($version in $script:PesterVersions) {
        It "passes a clean repo and names a tracked artifact (Pester $version)" {
            Invoke-InTestDir { param($d)
                $patterns = @('# generated output', 'logs/   # run logs', '**/__pycache__/*')
                New-ArtifactsRepo (Join-Path $d 'repo') -Files @('src/a.py') -Patterns $patterns
                $r = Invoke-ArtifactsSuite $d $version
                Assert-Equal '2/0' $r.Result $r.Text
                New-ArtifactsRepo (Join-Path $d 'repo') -Files @('src/__pycache__/a.pyc', 'logs/run.log') -Patterns $patterns
                $r = Invoke-ArtifactsSuite $d $version
                Assert-Equal '2/1' $r.Result $r.Text
                Assert-Match '2 tracked file\(s\) in .* are generated output' $r.Text
            }
        }

        It "fails a pattern file that matches nothing or is missing, and takes -Pattern instead (Pester $version)" {
            Invoke-InTestDir { param($d)
                New-ArtifactsRepo (Join-Path $d 'repo') -Files @('src/__pycache__/a.pyc') -Patterns @('**/__pycache__/')
                $r = Invoke-ArtifactsSuite $d $version
                Assert-Match '/[12]$' $r.Result "the dead pathspec must fail, got $($r.Result)"
                Assert-Match "matches no file: \*\*/__pycache__/\. Write '\*\*/__pycache__/\*'" $r.Text
                $r = Invoke-ArtifactsSuite $d $version -Data @{ Pattern = 'src/' }
                Assert-Equal '2/1' $r.Result $r.Text
                Remove-Item -LiteralPath (Join-Path $d 'repo\scripts') -Recurse -Force
                $r = Invoke-ArtifactsSuite $d $version
                Assert-Match '/[12]$' $r.Result
                Assert-Match 'no -Pattern and no pattern file' $r.Text
            }
        }
    }
}
