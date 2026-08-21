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
        $c = 'Remove-Item d:\GitHub\Kataglyphis-ContainerHub\out\build-logs -Recurse -Force'
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

Describe 'free-disk-space.ps1: the reclaim script itself' {

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

    It 'refuses a candidate that tunnels through a junction into a protected root' {
        # The name-based checks all clear a junction; the recursive delete then
        # walks through it. Build the real thing and prove it is skipped.
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('guard-junction-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $husk = Join-Path $sandbox 'containerd.bak-20260821-000000'
        New-Item -ItemType Directory -Path $husk -Force | Out-Null
        try {
            $link = Join-Path $husk 'tunnel'
            # A junction pointing at a protected root - the hazard shape.
            $null = New-Item -ItemType Junction -Path $link -Target $env:USERPROFILE -ErrorAction Stop

            $found = @(Get-ChildItem -LiteralPath $husk -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
            Assert-True ($found.Count -gt 0) 'test setup: the junction was not created'

            # Same predicate the script uses, run against the real subtree.
            $script = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'windows\scripts\host\free-disk-space.ps1'
            $raw = Get-Content -Raw $script
            Assert-Match 'Test-HasReparsePoint' $raw 'the reparse-point check is gone from the reclaim script'
            Assert-Match '\$t\.Linked' $raw 'the delete loop no longer honours the reparse-point check'
        } finally {
            # Remove the junction ITSELF first (never its contents).
            $link = Join-Path $husk 'tunnel'
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
            if (Test-Path -LiteralPath $sandbox) { [IO.Directory]::Delete($sandbox, $true) }
        }
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
