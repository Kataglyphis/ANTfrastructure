#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Pins Build-Buildkit.ps1's wiring of the per-run resource CSV, which the BK driver once lacked.

Describe 'BK driver resource sampler wiring (#134)' {

    BeforeAll {
        $repoWin = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:drv = Get-Content -Raw (Join-Path $repoWin 'Build-Buildkit.ps1')
    }

    It 'exposes a -NoResourceLog switch' {
        Assert-Match '\[switch\]\$NoResourceLog' $script:drv
    }

    It 'declares the phase file and Set-BuildPhase' {
        Assert-Match 'script:PhaseFile' $script:drv
        Assert-Match 'function Set-BuildPhase' $script:drv
    }

    It 'starts the sampler after preflight gates pass' {
        Assert-Match 'Build-ResourceSampler\.ps1' $script:drv
        Assert-Match '\$script:SamplerProc = Start-Process' $script:drv
    }

    It 'writes phase transitions in Invoke-BkStage' {
        Assert-Match '(?s)function Invoke-BkStage.*Set-BuildPhase \$Label' $script:drv
    }

    It 'stops the sampler and summarizes in the finally block' {
        Assert-Match '(?s)finally.*Stop-Process.*SamplerProc' $script:drv
        Assert-Match '(?s)finally.*-Summarize.*ResourceCsv' $script:drv
    }

    It 'forwards -NoResourceLog to concurrent child drivers (parent covers the machine)' {
        Assert-Match "(?s)ConcurrentAux.*auxArgs \+= '-NoResourceLog'" $script:drv
    }
}

Describe 'A stopped BK run keeps its record (hub #184)' {

    BeforeAll {
        $script:drv = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1'))
        $script:sampler = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-ResourceSampler.ps1'))
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Write-RunManifest')
    }

    It 'writes the manifest with a status, from the success path and from the finally of a failed run' {
        Assert-Match "Write-RunManifest -Status 'ok' -Elapsed \`$elapsed" $script:drv 'the green run'
        Assert-Match '(?s)\} finally \{.*RunSucceeded.*-eq \$false.*Write-RunManifest -Status "failed:\$\(\$script:CurrentPhase\)"' $script:drv 'the stopped run, before the sampler teardown'
        Assert-Match '(?s)function Invoke-BkStage.*\$script:CurrentPhase = \$Label\s*\r?\n.*\r?\n\s*Assert-StageDiskHeadroom' $script:drv 'a refusal names the stage it refused'
        Assert-Match '(?s)OK in \$\(\$script:StageTimings\[\$Label\]\)s"\s*\r?\n.*\r?\n\s*\$script:CurrentPhase = "after \$Label"' $script:drv 'a throw between stages is not charged to the one that passed'
        Assert-Match 'Get-Variable -Name started -Scope Script' $script:drv 'never a caller''s $started'
    }

    It 'gives each -ConcurrentAux child the parent''s run id with its branch, so their logs and manifests never collide' {
        Assert-Match "'-MediaBranches', \`$aux, '-MediaMemoryGb', \`$auxMem, '-ParentRunId', \`$script:RunId\)" $script:drv 'the parent passes its id'
        Assert-Match "\`$script:RunId = if \(\`$ParentRunId\) \{ `"\`$ParentRunId-\`$\(\`$MediaBranches -join '\+'\)`" \}" $script:drv 'the child names its run after it'
        Assert-Match "\[ValidatePattern\('\^\(\\d\{8\}-\\d\{6\}\)\?\$'\)\]\[string\]\`$ParentRunId" $script:drv 'only a run id, never a path'
    }

    It 'the manifest names its status and every finished stage (mutation)' {
        Invoke-InTestDir { param($d)
            $script:LogDir = $d; $script:RunId = '20261012-120000'
            $script:StageTimings = [ordered]@{ 'Dockerfile.base' = 1.5; 'toolchain-builder' = 30.2 }
            # The driver's own script variables, which the lifted function reads by name.
            Set-Variable -Name TargetArch -Value 'amd64'; Set-Variable -Name Variant -Value 'rocm'
            Set-Variable -Name Stages -Value @('base', 'toolchain', 'media'); Set-Variable -Name isNvidia -Value $false
            # A comma-decimal culture, as on the owner's host: an en-US runner would never see the regression.
            $culture = [cultureinfo]::CurrentCulture
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
            try { $path = Write-RunManifest -Status 'failed:media-core' -Elapsed ([timespan]::FromSeconds(42.04)) }
            finally { [cultureinfo]::CurrentCulture = $culture }
            $lines = @(Get-Content -LiteralPath $path)
            Assert-Equal 'run=20261012-120000 status=failed:media-core arch=amd64 variant=rocm stages=base,toolchain,media gpu=False total_s=42' $lines[0] 'the header line'
            Assert-Equal 'Dockerfile.base=1.5|toolchain-builder=30.2' ($lines[1..2] -join '|') 'the finished stages'
        }
    }

    It 'routes the driver log, decodes buildctl as UTF-8 and restores the console encoding' {
        Assert-Match 'Initialize-BuildDriverContext -DriverLog \$script:DriverLog' $script:drv 'the run''s driver log'
        Assert-False ($script:drv -match 'Write-DriverRecord \(".*\{\d:N\d\}') 'no record formats a number in the host''s culture ("2.415,0s")'
        Assert-Match '\[Console\]::OutputEncoding = \[System\.Text\.UTF8Encoding\]::new\(\$false\)' $script:drv 'UTF-8 for buildctl'
        Assert-Match '(?s)\} finally \{.*\[Console\]::OutputEncoding = \$script:PreviousOutputEncoding' $script:drv 'restored on every exit'
    }

    It 'samples the build drive''s free space into an eighth column, in the header, the row and the error row' {
        Assert-Match "'-Drive', \(Split-Path -Qualifier \`$repoRoot\)\.TrimEnd\(':'\)" $script:drv 'the drive the disk gate checks'
        $header = [regex]::Match($script:sampler, "'(ts,phase[^']*)'").Groups[1].Value
        Assert-Equal 'ts,phase,cpuPct,freeGB,usedGB,committedGB,vmmemGB,diskFreeGB' $header 'the header'
        foreach ($row in [regex]::Matches($script:sampler, '"\$\(Get-Date -Format ''yyyy-MM-dd HH:mm:ss''\),[^"]*"')) {
            Assert-Equal 7 ($row.Value.ToCharArray() | Where-Object { $_ -eq ',' }).Count "$($row.Value) has the header's eight fields"
        }
    }

    It 'summarises the free-disk minimum, and reads a CSV from before the column without it' {
        Invoke-InTestDir { param($d)
            [IO.File]::WriteAllLines("$d\new.csv", [string[]]('ts,phase,cpuPct,freeGB,usedGB,committedGB,vmmemGB,diskFreeGB',
                    '2026-10-12 10:00:00,litert,50,30,30,40,2,41.5', '2026-10-12 10:00:20,litert,60,29,31,41,2,18.2'))
            # A CSV the sampler wrote before 2026-10-12 has seven columns.
            [IO.File]::WriteAllLines("$d\old.csv", [string[]]('ts,phase,cpuPct,freeGB,usedGB,committedGB,vmmemGB', '2026-10-12 10:00:00,litert,50,30,30,40,2'))
            $sampler = Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-ResourceSampler.ps1'
            $new = (& $sampler -Summarize -CsvPath "$d\new.csv" 6>&1 | Out-String)
            Assert-Match 'MinDiskFreeGB' $new 'the new column in the summary'
            Assert-Match '18[.,]2' $new 'the lowest free disk, in the host''s number format'
            $old = (& $sampler -Summarize -CsvPath "$d\old.csv" 6>&1 | Out-String)
            Assert-Match 'litert' $old 'an old CSV still summarises'
        }
    }
}
