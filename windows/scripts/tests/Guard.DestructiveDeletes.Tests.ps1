#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The 2026-08-21 host wipe in executable form: every command shape that must
# never run again is asserted DENIED here, and the shapes that legitimately
# reclaim disk are asserted to survive. The guard is a PreToolUse hook
# (.claude\hooks\guard-destructive-deletes.ps1) - untested regexes in a
# safety gate are worse than no gate, because they read as protection.
#
# This file is on the guard's own exemption list; it is the one place in the
# repo allowed to spell out the forbidden command shapes verbatim.

$guard = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) '.claude\hooks\guard-destructive-deletes.ps1'

function Get-GuardDecision {
    # Returns 'deny', 'ask' or 'allow' (silence = no opinion = allow).
    param([string]$Tool, [string]$Command, [string]$FilePath, [string]$Content)

    $toolInput = @{ }
    if ($Command) { $toolInput['command'] = $Command }
    if ($FilePath) { $toolInput['file_path'] = $FilePath }
    if ($Content) { $toolInput['content'] = $Content }
    $json = @{ tool_name = $Tool; tool_input = $toolInput } | ConvertTo-Json -Depth 6 -Compress

    $out = & $guard -InputJson $json
    if (-not $out) { return 'allow' }
    return ($out | ConvertFrom-Json).hookSpecificOutput.permissionDecision
}

Describe 'guard-destructive-deletes: the protected roots' {

    It 'the guard script exists where the hooks point at it' {
        Assert-True (Test-Path $guard) "guard not found at $guard"
    }

    It 'denies a delete under the user profile (the 2026-08-21 shape)' {
        $c = 'Remove-Item "C:\Users\jonas\AppData\Local\Programs" -Recurse -Force'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies a delete under Program Files' {
        $c = 'Remove-Item -LiteralPath "C:\Program Files\Stevedore" -Recurse -Force'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies a delete under C:\Windows' {
        $c = 'Remove-Item C:\Windows\Installer\* -Recurse -Force'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies a drive-root wildcard delete' {
        $c = 'Remove-Item C:\* -Recurse -Force -ErrorAction SilentlyContinue'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies the bash spelling of a profile delete' {
        $c = 'rm -rf /c/Users/jonas/scoop'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'Bash' -Command $c)
    }

    It 'denies a per-user tool directory delete' {
        $c = 'Remove-Item "$env:USERPROFILE\.vscode\extensions" -Recurse -Force'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies uninstalling software, however it is spelled' {
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'Bash' -Command 'winget uninstall Microsoft.VisualStudioCode')
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command 'scoop uninstall llvm')
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command 'Get-AppxPackage *foo* | Remove-AppxPackage')
    }

    It 'denies a ProgramData delete outside the container stores' {
        $c = 'Remove-Item C:\ProgramData\Package Cache -Recurse -Force'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }
}

Describe 'guard-destructive-deletes: the reclaimable set still works' {

    It 'lets a container-store husk through as a prompt, never a block' {
        $c = 'Remove-Item "C:\ProgramData\containerd.bak-20260821-101500" -Recurse -Force'
        Assert-Equal 'ask' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'lets the buildkitd store husk through as a prompt, never a block' {
        $c = 'Remove-Item C:\ProgramData\buildkitd.bak-20260821-101500 -Recurse -Force'
        Assert-Equal 'ask' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'does not touch the daemon-level reclaim levers at all' {
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'PowerShell' -Command 'buildctl prune --free-storage 900000')
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'PowerShell' -Command 'docker image prune -f')
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'Bash' -Command 'bash linux/host-config/prune-safe.sh')
    }

    It 'asks (does not deny) for a recursive delete inside the repo' {
        $c = 'Remove-Item d:\GitHub\ContainerHub\out\build-logs -Recurse -Force'
        Assert-Equal 'ask' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }
}

Describe 'guard-destructive-deletes: no false positives on reading about deletes' {

    It 'stays silent when a delete verb appears only inside a quoted search pattern' {
        $c = 'grep -rn "Remove-Item" --include=*.ps1 windows/ | head -20'
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'Bash' -Command $c)
    }

    It 'stays silent on git rm' {
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'Bash' -Command 'git rm --cached windows/out/stale.log')
    }

    It 'stays silent on an ordinary build invocation' {
        $c = 'pwsh -NoProfile -ExecutionPolicy Bypass -File windows\build.ps1 -Gpu -Stages media,final'
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }
}

Describe 'guard-destructive-deletes: the copy-paste vector' {

    It 'denies WRITING a script that deletes from a protected root' {
        # The actual 2026-08-21 vector: the agent never ran the command, it
        # handed the user a script to paste into an elevated shell.
        $body = @'
$targets = @("C:\Program Files\Stevedore", "$env:LOCALAPPDATA\Programs")
foreach ($t in $targets) { Remove-Item $t -Recurse -Force }
'@
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'Write' -FilePath 'C:\tmp\free-space.ps1' -Content $body)
    }

    It 'allows writing a store-only cleanup script' {
        $body = @'
Stop-Service buildkitd -Force
Remove-Item "C:\ProgramData\buildkitd.bak-20260821" -Recurse -Force
Start-Service buildkitd
'@
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'Write' -FilePath 'C:\tmp\reset-store.ps1' -Content $body)
    }
}

Describe 'free-disk-space.ps1: what it cleans, and what it refuses to' {

    # Dot-sourcing gives the functions without running anything.
    $reclaim = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'windows\scripts\host\free-disk-space.ps1'
    . $reclaim

    It 'refuses every protected root, and the drive roots' {
        foreach ($p in @('C:\', 'D:\', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\Windows',
                'C:\Users', 'C:\ProgramData', $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
            Assert-True (Test-Protected $p) "protected root not refused: $p"
        }
    }

    It 'still permits the genuinely reclaimable paths' {
        foreach ($p in @('C:\ProgramData\containerd.bak-20260821-101500',
                (Join-Path $env:TEMP 'some-stale-dir'),
                'C:\Windows\Temp\stale')) {
            Assert-False (Test-Protected $p) "reclaimable path wrongly refused: $p"
        }
    }

    It 'the rule table covers temp and layers but never programs or compile caches' {
        $rules = Get-ReclaimRules -TempAgeDays 7
        $roots = ($rules | ForEach-Object { $_.Root }) -join ' | '
        Assert-Match 'Temp' $roots 'no temp rule - the cleanup does not cover temp files'
        Assert-Match 'ProgramData' $roots 'no container-store rule'
        foreach ($never in @('Program Files', 'sccache', 'ccache', '\.cargo', '\.vscode', 'scoop', 'Downloads', 'Package Cache')) {
            Assert-False ($roots -match $never) "the allowlist reaches something it must never touch: $never"
        }
        # Every live-directory rule must be age-gated; only the dead husks may be 0.
        foreach ($r in ($rules | Where-Object { $_.Root -match 'Temp' })) {
            Assert-True ($r.MinAgeDays -ge 1) "temp rule is not age-gated: $($r.Root)"
        }
    }

    It 'age-gates: work in flight survives, stale entries are candidates' {
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('reclaim-age-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        try {
            $fresh = New-Item -ItemType Directory -Path (Join-Path $sandbox 'scratch-fresh') -Force
            $stale = New-Item -ItemType Directory -Path (Join-Path $sandbox 'scratch-stale') -Force
            $stale.LastWriteTime = (Get-Date).AddDays(-30)

            $rules = @(@{ Root = $sandbox; Leaf = 'scratch-*'; Kind = 'Directory'; MinAgeDays = 7; What = 'fixture' })
            $plan = Get-ReclaimPlan -Rules $rules
            $paths = @($plan | ForEach-Object { $_.Path })

            Assert-True ($paths -contains $stale.FullName) 'a 30-day-old entry was not offered'
            Assert-False ($paths -contains $fresh.FullName) 'a FRESH entry was offered - work in flight would be deleted'
        } finally {
            if (Test-Path -LiteralPath $sandbox) { [IO.Directory]::Delete($sandbox, $true) }
        }
    }

    It 'marks a candidate containing a junction so the delete skips it' {
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('reclaim-link-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $husk = Join-Path $sandbox 'scratch-linked'
        New-Item -ItemType Directory -Path $husk -Force | Out-Null
        $link = Join-Path $husk 'tunnel'
        # Counted BEFORE the tunnel exists, for the canary test below.
        $script:profileEntriesBefore = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -ErrorAction SilentlyContinue).Count
        try {
            # A junction into a protected root: the exact tunnel shape.
            $null = New-Item -ItemType Junction -Path $link -Target $env:USERPROFILE -ErrorAction Stop
            (Get-Item -LiteralPath $husk -Force).LastWriteTime = (Get-Date).AddDays(-30)

            Assert-True (Test-HasReparsePoint $husk) 'the junction inside the candidate was not detected'

            $plan = Get-ReclaimPlan -Rules @(@{ Root = $sandbox; Leaf = 'scratch-*'; Kind = 'Directory'; MinAgeDays = 7; What = 'fixture' })
            $entry = $plan | Where-Object { $_.Path -eq $husk } | Select-Object -First 1
            Assert-NotNull $entry 'the fixture candidate did not resolve'
            Assert-True $entry.Linked 'the candidate was NOT marked as linked - a delete would tunnel into the profile'
        } finally {
            # Remove the junction ITSELF first, never its contents.
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
            if (Test-Path -LiteralPath $sandbox) { [IO.Directory]::Delete($sandbox, $true) }
        }
    }

    It 'the user profile is still intact after the junction fixture' {
        # Paranoia with teeth: if the teardown above ever deleted THROUGH the
        # junction, this is what would notice.
        #
        # The canary is the profile's own ENTRY COUNT, taken before the tunnel
        # was created, plus AppData -- which every Windows profile has. It used
        # to be `.claude`, which exists on a developer box and NOT on a CI
        # runner, so this test failed there for a reason that had nothing to do
        # with deleting anything (2026-08-27). A count that only has to be
        # >= the earlier one tolerates files appearing mid-run while still
        # catching the wholesale emptying this exists to catch.
        Assert-True (Test-Path -LiteralPath $env:USERPROFILE) 'the user profile is gone'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'AppData')) 'the profile was emptied through a junction'
        Assert-NotNull $script:profileEntriesBefore 'the junction fixture never ran, so this canary proves nothing'
        $after = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -ErrorAction SilentlyContinue).Count
        Assert-True ($after -ge $script:profileEntriesBefore) `
            "the profile lost entries through the junction ($script:profileEntriesBefore -> $after)"
    }

    It 'is report-only by default and never deletes without -Apply' {
        $script = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'windows\scripts\host\free-disk-space.ps1'
        Assert-True (Test-Path $script) "reclaim script not found at $script"
        $raw = Get-Content -Raw $script
        # The delete is downstream of the -Apply gate: the report path exits
        # before it. A refactor that moves the delete above the gate fails here.
        $applyGate = $raw.IndexOf('if (-not $Apply)')
        $delete = $raw.IndexOf('Remove-Item -LiteralPath $t.Path')
        Assert-True ($applyGate -gt 0) 'the -Apply gate is gone'
        Assert-True ($delete -gt $applyGate) 'a delete now sits ABOVE the -Apply gate'
    }

    It 'honours the linked flag at delete time, not just in the report' {
        $script = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'windows\scripts\host\free-disk-space.ps1'
        $raw = Get-Content -Raw $script
        Assert-Match 'Test-HasReparsePoint' $raw 'the reparse-point check is gone from the reclaim script'
        Assert-Match '\$t\.Linked' $raw 'the delete loop no longer honours the reparse-point check'
        Assert-Match 'Test-Protected \$t\.Path' $raw 'the delete loop no longer re-checks the protected roots'
    }

    It 'runs on pwsh 7 like the rest of the repo' {
        $script = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'windows\scripts\host\free-disk-space.ps1'
        Assert-Match '(?m)^#requires -Version 7\.0' (Get-Content -Raw $script) 'the reclaim script is not pinned to pwsh 7'
    }
}

Describe 'guard-destructive-deletes: the hook is actually registered' {

    It 'project settings wire the guard into PreToolUse' {
        $settings = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) '.claude\settings.json'
        Assert-True (Test-Path $settings) 'project .claude\settings.json is missing'
        $raw = Get-Content -Raw $settings
        Assert-Match 'guard-destructive-deletes' $raw 'the guard is not registered as a hook'
        Assert-Match 'PreToolUse' $raw 'the guard is not registered on PreToolUse'
    }

    It 'no settings file hands out a blanket delete permission' {
        # The allow rule that let the wipe run without a prompt.
        $root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
        foreach ($f in @('.claude\settings.json', '.claude\settings.local.json')) {
            $p = Join-Path $root $f
            if (-not (Test-Path $p)) { continue }
            $raw = Get-Content -Raw $p
            # Materialise the matches before reporting: under StrictMode a
            # member access on an EMPTY MatchCollection throws, so the
            # pass-case message would fail instead of the assertion.
            $blanket = @([regex]::Matches($raw, '"(?:PowerShell|Bash)\((?:Remove-Item|rm)\s\*\)"') |
                    ForEach-Object { $_.Value })
            Assert-Equal 0 $blanket.Count "$f still allow-lists a blanket delete: $($blanket -join ', ')"
        }
    }
}

Describe 'guard-destructive-deletes: the GPU-driver pattern is proximity-scoped' {

    # Added 2026-08-25. The vendor-word pattern (nvidia|adrenalin|radeon) is the
    # only protected pattern that is not path-shaped, so it matched bare English
    # anywhere in a text and denied ordinary documentation edits - six times in
    # one day, on prose whose only delete-shaped token was a container run flag.
    # It is now scoped to a delete verb within 200 characters. These tests pin
    # BOTH halves: the false positives stop, and every real shape still dies.
    # Proximity, not same-line: a real script assigns the path on one line and
    # deletes on the next, and a line-scoped rule would stop seeing it.

    It 'denies deleting a GPU driver directory outside the standard roots' {
        $c = 'Remove-Item -Recurse -Force D:\NVIDIA\DisplayDriver'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies it when the path is assigned on an earlier line (why not same-line)' {
        $c = "`$stale = `"D:\AMD\Adrenalin\cache`"`nRemove-Item -Recurse -Force `$stale"
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }

    It 'denies a script written for the user to paste (the 2026-08-21 vector)' {
        $c = "# free some space`nRemove-Item -Recurse -Force 'C:\Program Files\NVIDIA Corporation'"
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'Write' -FilePath 'cleanup.ps1' -Content $c)
    }

    It 'allows prose naming a GPU vendor far from an unrelated delete-shaped flag' {
        # The exact shape that blocked six documentation edits: a container run
        # example whose --rm matches \brm\b, and a vendor word far away.
        $c = 'An ENABLED AMD RDNA4 dGPU makes every RUN-layer finalize fail.' +
             ("`nfiller prose to push the two apart. " * 40) +
             "`n    nerdctl run -it --rm ghcr.io/example/image:tag"
        Assert-Equal 'allow' (Get-GuardDecision -Tool 'Write' -FilePath 'docs\notes.md' -Content $c)
    }

    It 'still denies when the vendor word and the delete are close together' {
        $c = 'To reclaim space, Remove-Item -Recurse C:\radeon-cache and reboot.'
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'Write' -FilePath 'docs\notes.md' -Content $c)
    }

    It 'keeps the path-shaped patterns unscoped (a profile delete needs no proximity)' {
        $c = '$target = "C:\Users\jonas\AppData\Local\Programs"' +
             ("`n# commentary " * 60) +
             "`nRemove-Item -Recurse -Force `$target"
        Assert-Equal 'deny' (Get-GuardDecision -Tool 'PowerShell' -Command $c)
    }
}
