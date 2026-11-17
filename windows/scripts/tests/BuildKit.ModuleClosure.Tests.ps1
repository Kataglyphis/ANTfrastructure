#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

# A mounted script's transitive imports must all be mounted, and leaf stages must keep one consumer; BuildKit checks neither.

Describe 'BuildKit module closure' {

    BeforeAll {
        $script:repoRoot  = Get-RepoRoot
        $script:moduleDir = Join-Path $script:repoRoot 'windows\scripts\modules'
        $script:buildDir  = Join-Path $script:repoRoot 'windows\scripts\build'
        $script:hostDir   = Join-Path $script:repoRoot 'windows\scripts\host'

        # Every `modules\<Name>.psm1` reference; bare names are matched separately so foreach lists count.
        function script:Get-ReferencedModules {
            param([string]$Path)
            $t = [System.IO.File]::ReadAllText($Path)
            $names = @([regex]::Matches($t, '(?i)modules[\\/]([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
            # The bare-name idiom (`foreach ($m in 'WindowsX.Y', 'WindowsZ.W')`) names no path; the dot keeps env vars like 'WindowsSdkDir' out.
            $names += @([regex]::Matches($t, "(?i)'(Windows[A-Za-z0-9._]*?\.[A-Za-z0-9]+?)(?:\.psm1)?'") | ForEach-Object { $_.Groups[1].Value })
            @($names | Sort-Object -Unique)
        }

        # Per RUN: the module stage or module files it mounts, and its build scripts.
        function script:Get-RunMounts {
            param([string]$DockerfilePath)
            $runs = @()
            foreach ($line in (Get-TestDockerLogicalLine -LiteralPath $DockerfilePath)) {
                if ($line -notmatch '^RUN\s') { continue }
                $runs += [pscustomobject]@{
                    Line          = $line
                    FromStages    = @([regex]::Matches($line, 'from=([A-Za-z0-9_.-]+),source=[^,]*bkmods') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                    SingleModules = @([regex]::Matches($line, 'source=windows/scripts/modules/([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                    Scripts       = @([regex]::Matches($line, 'source=windows/scripts/(?:build|host)/([A-Za-z0-9._-]+)\.ps1') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                }
            }
            $runs
        }

        # Follows `FROM <parent> AS <name>` so a derived stage inherits its parent's modules.
        function script:Get-ModuleStages {
            param([string]$DockerfilePath)
            $facts = Get-TestDockerfileStageFacts -Path $DockerfilePath
            $stages = @{}
            foreach ($name in $facts.Keys) {
                if ($name -notmatch '^[\w.-]+$') { continue }
                $stages[$name] = @($facts[$name].MountedModules)
            }
            # inherit through FROM <stage> AS <derived>
            foreach ($s in @($stages.Keys)) {
                $chain = @(); $cur = $s
                while ($cur -and $stages.ContainsKey($cur)) {
                    $chain += $stages[$cur]
                    $cur = $facts[$cur].Parent
                }
                $stages[$s] = @($chain | Sort-Object -Unique)
            }
            $stages
        }

        function script:Get-RunModuleClosureReport {
            param([string[]]$DockerfilePaths, [string]$BuildDir, [string]$HostDir, [string]$ModuleDir)
            $missing = @()
            $checked = 0
            foreach ($df in $DockerfilePaths) {
                $stages = Get-ModuleStages -DockerfilePath $df
                foreach ($run in (Get-RunMounts -DockerfilePath $df)) {
                    if ($run.Scripts -and ($run.FromStages -or $run.SingleModules)) { $checked++ }
                    if (-not $run.Scripts) { continue }
                    $available = @($run.SingleModules)
                    foreach ($sourceStage in $run.FromStages) {
                        if ($stages.ContainsKey($sourceStage)) { $available += $stages[$sourceStage] }
                    }
                    $available = @($available | Sort-Object -Unique)
                    if (-not $available) { continue }
                    foreach ($scriptName in $run.Scripts) {
                        $scriptPath = @((Join-Path $BuildDir "$scriptName.ps1"), (Join-Path $HostDir "$scriptName.ps1")) |
                            Where-Object { Test-Path $_ } | Select-Object -First 1
                        if (-not $scriptPath) { continue }
                        $needed = Get-ModuleImportClosure -Seed (Get-ReferencedModules -Path $scriptPath) -ModuleDir $ModuleDir
                        $absent = @($needed | Where-Object { $_ -notin $available })
                        if ($absent) { $missing += "$(Split-Path $df -Leaf) / $scriptName.ps1 -> missing [$($absent -join ', ')]; mounted [$($available -join ', ')]" }
                    }
                }
            }
            return [pscustomobject]@{ Missing = $missing; Checked = $checked }
        }

        $script:mediaDf = Join-Path $script:repoRoot 'windows\Dockerfile.media-builder'
        $script:mergeDf = Join-Path $script:repoRoot 'windows\Dockerfile.media-merge-builder'
    }

    It 'every mounted build script''s transitive module closure is present in that RUN' {
        $report = Get-RunModuleClosureReport -DockerfilePaths @($script:mediaDf, $script:mergeDf) -BuildDir $script:buildDir -HostDir $script:hostDir -ModuleDir $script:moduleDir
        $report.Checked | Should -BeGreaterThan 5 -Because 'the RUN/mount scan found almost nothing — the Dockerfile layout moved and this gate is checking air'
        $report.Missing | Should -BeNullOrEmpty -Because ("a module imported at RUN time but not mounted throws 'Required module not found' " +
            "inside the container, typically ~40 min into a compile, and never on a dev box where the whole modules dir is on disk:`n  " + ($report.Missing -join "`n  "))
    }

    It 'keeps the TVM leaf module OUT of the shared buildmods closure' {
        $stages = Get-ModuleStages -DockerfilePath $script:mediaDf
        $stages.Keys | Should -Contain 'buildmods'
        $stages.Keys | Should -Contain 'tvmmods' -Because 'the TVM-private module stage is what #134 bought; without it the leaf is back in the shared closure'
        # Every media RUN mounts buildmods, so a TVM-only module there re-keys the ONNX branch.
        @($stages['buildmods']) | Should -Not -Contain 'WindowsTvm.Common' `
            -Because 'WindowsTvm.Common belongs to tvmmods; in buildmods it re-keys ONNX, OpenCV and FFmpeg for a TVM-only change'
        @($stages['tvmmods']) | Should -Contain 'WindowsTvm.Common'
    }

    It 'mounts tvmmods from exactly one RUN' {
        $consumers = @(Get-RunMounts -DockerfilePath $script:mediaDf | Where-Object { $_.FromStages -contains 'tvmmods' })
        # A second consumer means the code is shared and belongs in buildmods.
        $consumers.Count | Should -Be 1 -Because 'a second tvmmods consumer means the code is shared and belongs in buildmods; widening this stage spends the cache win silently'
        $consumers[0].Scripts | Should -Contain 'Build-MediaTvmAll' -Because 'tvmmods exists for the media-tvm branch'
    }

    It 'keeps the merge-only leaf modules OUT of the media lane entirely' {
        $mediaStages = Get-ModuleStages -DockerfilePath $script:mediaDf
        $mergeStages = Get-ModuleStages -DockerfilePath $script:mergeDf
        foreach ($leaf in @('WindowsMeson.Common', 'WindowsRustToolchain.Common', 'WindowsGstPlugins.Common')) {
            @($mergeStages['buildmods']) | Should -Contain $leaf -Because "the GStreamer build is $leaf's only consumer"
            foreach ($st in $mediaStages.Keys) {
                @($mediaStages[$st]) | Should -Not -Contain $leaf `
                    -Because "$leaf in media-builder's $st would re-run every media compile RUN for merge-only code"
            }
        }
    }

    It 'no chain stage bind-mounts the WHOLE modules directory' {
        # Dockerfile.probe is exempt: PROBE_NONCE busts its layer anyway. See docs/windows-build-invariants.md § A whole-directory modules mount puts EVERY module in the cache key
        $offenders = @()
        foreach ($df in (Get-ChildItem -Path $script:repoRoot -Filter 'Dockerfile*' -File -Recurse |
                         Where-Object { $_.FullName -like '*\windows\*' -and $_.Name -ne 'Dockerfile.probe' })) {
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($df.FullName),
                            '(?im)^\s*.*--mount=type=bind,source=windows/scripts/modules,')) {
                $offenders += "$($df.Name): $($m.Value.Trim())"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ("a whole-directory modules mount makes every module edit re-key that RUN; " +
            "mount the per-file closure the script actually imports:`n  " + ($offenders -join "`n  "))
    }
}
