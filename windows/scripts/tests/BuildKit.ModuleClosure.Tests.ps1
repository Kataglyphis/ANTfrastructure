#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The module CLOSURE gate (#134). Two properties, both of which BuildKit will
# happily let you break, and neither of which any other suite watches:
#
#  (1) COMPLETENESS — every module a mounted build script imports, transitively,
#      must actually be in the module set that RUN mounts. Get it wrong and the
#      failure is a "Required module not found" thrown ~40 minutes into a
#      compile stage, on the build host only, because the script runs fine
#      locally where the whole modules dir is on disk.
#
#  (2) MINIMALITY OF THE LEAF STAGES — the media lane's `tvmmods` and the merge
#      lane's leaf modules exist to keep TVM-only and GStreamer-only code OUT of
#      the six-module closure that every media RUN mounts. That win is invisible
#      and evaporates the moment someone adds a second consumer or moves a leaf
#      module into `buildmods`. Nothing would fail; the branches would just
#      quietly start re-keying each other again.
#
# This is the Windows analogue of linux/scripts/verify_script_copy_coverage.py,
# which globs linux/Dockerfile.* only and has never policed the Windows lane.

Describe 'BuildKit module closure' {

    BeforeAll {
        $script:repoRoot  = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
        $script:moduleDir = Join-Path $script:repoRoot 'windows\scripts\modules'
        $script:buildDir  = Join-Path $script:repoRoot 'windows\scripts\build'

        # Every `modules\<Name>.psm1` mentioned in a file, whatever the idiom
        # (Join-Path .. 'modules\X.psm1', a foreach list of bare names, a COPY
        # line). Bare-name form is matched separately so the foreach list in
        # Build-GstreamerFromSource.ps1 counts.
        function script:Get-ReferencedModules {
            param([string]$Path)
            $t = [System.IO.File]::ReadAllText($Path)
            $names = @([regex]::Matches($t, '(?i)modules[\\/]([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
            $names += @([regex]::Matches($t, "(?i)'(Windows[A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value })
            @($names | Sort-Object -Unique)
        }

        # A module's own sibling imports: Join-Path $PSScriptRoot 'X.psm1'.
        function script:Get-ModuleSiblingImports {
            param([string]$ModuleName)
            $p = Join-Path $script:moduleDir "$ModuleName.psm1"
            if (-not (Test-Path $p)) { return @() }
            $t = [System.IO.File]::ReadAllText($p)
            @([regex]::Matches($t, "(?i)PSScriptRoot\s+'([A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }

        function script:Get-TransitiveClosure {
            param([string[]]$Seed)
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $queue = [System.Collections.Generic.Queue[string]]::new()
            foreach ($s in $Seed) { [void]$queue.Enqueue($s) }
            while ($queue.Count -gt 0) {
                $n = $queue.Dequeue()
                if (-not $seen.Add($n)) { continue }
                foreach ($sib in (Get-ModuleSiblingImports -ModuleName $n)) { [void]$queue.Enqueue($sib) }
            }
            @($seen) | Sort-Object
        }

        # Parse a Dockerfile into RUN records: which module-carrying stage it
        # mounts (from=<stage>) or which single modules it mounts by file, and
        # which build scripts it mounts.
        function script:Get-RunMounts {
            param([string]$DockerfilePath)
            $joined = ([System.IO.File]::ReadAllText($DockerfilePath)) -replace '`\r?\n', ' '
            $runs = @()
            foreach ($line in ($joined -split "`n")) {
                if ($line -notmatch '^RUN\s') { continue }
                $runs += [pscustomobject]@{
                    Line          = $line
                    FromStages    = @([regex]::Matches($line, 'from=([A-Za-z0-9_.-]+),source=[^,]*bkmods') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                    SingleModules = @([regex]::Matches($line, 'source=windows/scripts/modules/([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                    Scripts       = @([regex]::Matches($line, 'source=windows/scripts/build/([A-Za-z0-9._-]+)\.ps1') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                }
            }
            $runs
        }

        # stage -> the modules its COPY lines put into C:\bkmods, following
        # `FROM <parent> AS <name>` so a derived stage inherits its parent's set.
        function script:Get-ModuleStages {
            param([string]$DockerfilePath)
            $joined = ([System.IO.File]::ReadAllText($DockerfilePath)) -replace '`\r?\n', ' '
            $stages = @{}
            $parents = @{}
            $current = ''
            foreach ($line in ($joined -split "`n")) {
                if ($line -match '^FROM\s+(\S+)\s+AS\s+([\w.-]+)') {
                    $current = $Matches[2]
                    $parents[$current] = $Matches[1]
                    if (-not $stages.ContainsKey($current)) { $stages[$current] = @() }
                    continue
                }
                if ($current -and $line -match '^COPY\s' -and $line -match 'bkmods') {
                    $stages[$current] += @([regex]::Matches($line, '(?i)modules[\\/]([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
                }
            }
            # inherit through FROM <stage> AS <derived>
            foreach ($s in @($stages.Keys)) {
                $chain = @(); $cur = $s
                while ($cur -and $stages.ContainsKey($cur)) {
                    $chain += $stages[$cur]
                    $cur = if ($parents.ContainsKey($cur)) { $parents[$cur] } else { $null }
                }
                $stages[$s] = @($chain | Sort-Object -Unique)
            }
            $stages
        }

        $script:mediaDf = Join-Path $script:repoRoot 'windows\Dockerfile.media-builder'
        $script:mergeDf = Join-Path $script:repoRoot 'windows\Dockerfile.media-merge-builder'
    }

    It 'every mounted build script''s transitive module closure is present in that RUN' {
        $bad = @()
        foreach ($df in @($script:mediaDf, $script:mergeDf)) {
            $stages = Get-ModuleStages -DockerfilePath $df
            foreach ($run in (Get-RunMounts -DockerfilePath $df)) {
                if (-not $run.Scripts) { continue }
                $available = @($run.SingleModules)
                foreach ($st in $run.FromStages) {
                    if ($stages.ContainsKey($st)) { $available += $stages[$st] }
                }
                $available = @($available | Sort-Object -Unique)
                if (-not $available) { continue }   # a RUN that mounts no modules at all
                foreach ($s in $run.Scripts) {
                    $sp = Join-Path $script:buildDir "$s.ps1"
                    if (-not (Test-Path $sp)) { continue }
                    $needed = Get-TransitiveClosure -Seed (Get-ReferencedModules -Path $sp)
                    $missing = @($needed | Where-Object { $_ -notin $available })
                    if ($missing) { $bad += "$(Split-Path $df -Leaf) / $s.ps1 -> missing [$($missing -join ', ')]; mounted [$($available -join ', ')]" }
                }
            }
        }
        # Scanner-rot guard: if the parse stops finding RUNs with scripts AND
        # modules, an empty $bad would report green while checking nothing.
        $checked = 0
        foreach ($df in @($script:mediaDf, $script:mergeDf)) {
            foreach ($run in (Get-RunMounts -DockerfilePath $df)) {
                if ($run.Scripts -and ($run.FromStages -or $run.SingleModules)) { $checked++ }
            }
        }
        $checked | Should -BeGreaterThan 5 -Because 'the RUN/mount scan found almost nothing — the Dockerfile layout moved and this gate is checking air'
        $bad | Should -BeNullOrEmpty -Because ("a module imported at RUN time but not mounted throws 'Required module not found' " +
            "inside the container, typically ~40 min into a compile, and never on a dev box where the whole modules dir is on disk:`n  " + ($bad -join "`n  "))
    }

    It 'keeps the TVM leaf module OUT of the shared buildmods closure' {
        $stages = Get-ModuleStages -DockerfilePath $script:mediaDf
        $stages.Keys | Should -Contain 'buildmods'
        $stages.Keys | Should -Contain 'tvmmods' -Because 'the TVM-private module stage is what #134 bought; without it the leaf is back in the shared closure'
        # buildmods is mounted by every media RUN. A TVM-only module there means
        # a TVM constant re-keys the ~75 min ONNX branch again.
        @($stages['buildmods']) | Should -Not -Contain 'WindowsTvm.Common' `
            -Because 'WindowsTvm.Common belongs to tvmmods; in buildmods it re-keys ONNX, OpenCV and FFmpeg for a TVM-only change'
        @($stages['tvmmods']) | Should -Contain 'WindowsTvm.Common'
    }

    It 'mounts tvmmods from exactly one RUN' {
        $consumers = @(Get-RunMounts -DockerfilePath $script:mediaDf | Where-Object { $_.FromStages -contains 'tvmmods' })
        # Two consumers means the module is shared, and shared code belongs in
        # buildmods -- at which point this stage is pure indirection and the
        # comment above it is telling a story that is no longer true.
        $consumers.Count | Should -Be 1 -Because 'a second tvmmods consumer means the code is shared and belongs in buildmods; widening this stage spends the cache win silently'
        # 'Build-MediaTvmAll', not 'build-media-tvm-all': renamed in the
        # approved-verb sweep; the expectation was left on the old name.
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
        # A directory mount puts EVERY module in the RUN's cache key, so editing any
        # one of them re-keys that compile. Dockerfile.toolchain-builder's patched-llvm
        # RUN did this and it is the DEFAULT toolchain target, so a host-only module edit
        # silently re-paid a full LLVM build plus the media lanes that derive from it.
        # Dockerfile.probe is exempt BY DESIGN: PROBE_NONCE busts its layer anyway and it
        # dispatches arbitrary diagnostic scripts (its own header states this).
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
